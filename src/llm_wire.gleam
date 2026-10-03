//// Prepares, runs and streams LLM calls through an application-owned
//// `http_gun.Client`.
////
//// ```gleam
//// import gleam/io
//// import http_gun
//// import http_gun/config as http_config
//// import llm_wire
//// import llm_wire/openai
////
//// pub fn main() -> Nil {
////   let assert Ok(client) = http_gun.start(http_config.default())
////   let config = openai.new("sk-...") |> openai.config
////   let request = llm_wire.request("gpt-5", [llm_wire.user("Hello")])
////   let assert Ok(prepared) = llm_wire.prepare(config, request)
////   case llm_wire.run(client, prepared) {
////     Ok(llm_wire.Answer(text:, ..)) -> io.println(text)
////     Ok(_) -> io.println("no final answer")
////     Error(failure) -> io.println(llm_wire.describe_failure(failure))
////   }
////   http_gun.stop(client)
//// }
//// ```
////
//// `prepare` is pure: it checks the configuration, messages, tools and
//// schemas and encodes the request once, before any I/O. `run` executes it
//// to an `Outcome`; `stream` returns a `Stream` read with `next` until
//// `Done`. A prepared call can run again, for a retry. Structured output is
//// one more request step, `with_output(name, codec)`: the `Answer` then
//// holds the decoded value, and invalid output fails with
//// `error.InvalidOutput`, keeping the raw text.
////
//// The caller owns the conversation and the tool loop: on `NeedsTools`,
//// append the turn and one `tool_result` per call, and prepare the next
//// request. LLM Wire never retries; `advise(failure)` says whether another
//// attempt may help and how long to wait.
////
//// | Default | Value | Setter |
//// | --- | --- | --- |
//// | whole call, start to final event | 600 s | `with_call_timeout` |
//// | first token, start to first progress | 180 s | `with_first_token_timeout` |
//// | idle gap between provider events | 60 s, reset by every event | `with_idle_timeout` |
//// | byte and count bounds | see `llm_wire/limit` | `with_limit` |
//// | invalid tool calls | fail the response | `with_tool_call_checks` |
//// | plaintext `http://` | loopback addresses only | none: HTTP Gun's destination policy |
////
//// Each call's whole-call budget replaces the HTTP Gun client's request
//// timeout and lifts its idle timeout, so a client default never cuts an
//// LLM call; the client's connect and pool timeouts, destination policy and
//// trust still apply.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/duration.{type Duration}
import http_gun
import http_gun/error as http_error
import json/blueprint/codec
import json/blueprint/contract
import llm_wire/error.{type Error, type PrepareError}
import llm_wire/internal/adapter
import llm_wire/internal/api
import llm_wire/internal/call
import llm_wire/internal/config
import llm_wire/internal/http_client
import llm_wire/internal/limits
import llm_wire/internal/observe
import llm_wire/internal/owner
import llm_wire/internal/retry_after
import llm_wire/internal/stream_types
import llm_wire/internal/tool_def
import llm_wire/limit.{type Limit}
import llm_wire/message.{
  type AssistantTurn, type Message, type Progress, type Provider, type ToolCall,
  type Usage,
}
import llm_wire/telemetry
import llm_wire/tool.{type Tool, type ToolCallChecks, type ToolCallIssue}

/// A provider and its execution settings, built by `llm_wire/openai`,
/// `llm_wire/anthropic`, `llm_wire/google` or `llm_wire/provider`. It is
/// pure data, opens nothing, and never prints its API key.
pub type Config =
  config.Config

/// A request whose answer decodes to `o`: `String` for plain text, or the
/// type of the codec given to `with_output`.
pub type Request(o) =
  call.Request(o)

/// A request admitted and encoded for one configuration. Run it any number
/// of times.
pub type Prepared(o) =
  call.Prepared(o)

/// An executing call. Read it with `next` until `Done`; `close` ends it
/// early. Only the process that started it may read it, one read at a time.
pub type Stream(o) =
  call.Stream(o)

/// A time bound that may be lifted. `Infinity` must be chosen explicitly.
pub type Bound {
  After(Duration)
  Infinity
}

/// How a call ended without failing. Read fields by label.
pub type Outcome(o) {
  /// The final answer. `output` is the text for a plain request, or the
  /// decoded value for a request built with `with_output`.
  Answer(output: o, text: String, usage: Option(Usage))
  /// The model asks for tool results. Append `message.Assistant(turn)` and
  /// one `tool_result` per call to the conversation. `issues` lists calls
  /// that failed admission under `tool.ReportInvalidToolCalls`.
  NeedsTools(
    turn: AssistantTurn,
    issues: List(ToolCallIssue),
    usage: Option(Usage),
  )
  /// The output token limit cut the answer.
  OutputLimited(
    partial_text: String,
    partial_calls: List(ToolCall),
    usage: Option(Usage),
  )
  Refused(reason: String, usage: Option(Usage))
}

/// One item of a stream.
pub type Event(o) {
  Progress(Progress)
  /// The call ended; the stream is finished.
  Done(Result(Outcome(o), Failure))
}

/// Whether the request reached the provider.
pub type Sent {
  /// Nothing reached the network; another attempt cannot repeat any work.
  NotSent
  /// The provider may have received the request and spent tokens on it.
  MaybeSent
  /// The provider finished its response, with an error status, a reported
  /// error or content that failed admission.
  Completed
}

/// A failed call. Read fields by label; it may gain fields.
pub type Failure {
  Failure(
    error: Error,
    sent: Sent,
    /// Whether progress, such as text, had streamed before the failure.
    partial_output: Bool,
    provider: Provider,
    /// The last usage the provider reported, for token accounting.
    usage: Option(Usage),
  )
}

/// Why a read returned no event.
pub type ReadError {
  /// The stream already delivered `Done` or was closed.
  StreamEnded
  /// Another read of this stream is waiting.
  ConcurrentRead
  /// The call's owner process is gone.
  OwnerGone
  /// `next_within` waited its whole duration; the stream stays readable.
  TimedOut
}

pub type CloseOutcome {
  /// The call was running and is now cancelled.
  Closed
  /// The call had already ended.
  AlreadyEnded
}

/// Whether another attempt of the same prepared call may succeed.
pub type RetryProspect {
  /// The failure may be transient. Another attempt is not guaranteed to
  /// succeed, and `failure.sent` says whether the first one cost tokens.
  MayHelp
  /// The request, configuration, limits, account or cancellation must
  /// change first.
  WillNotHelpUnchanged
  /// The failure does not establish a prospect.
  Unknown
}

/// The retry decision for a failure and when to act on it. Read the fields
/// by label; it may gain fields.
pub type RetryAdvice {
  RetryAdvice(prospect: RetryProspect, delay: RetryDelay)
}

/// How long to wait before another attempt, and who chose the time. A
/// scheduler that distinguishes the two can snooze for a provider's delay
/// without counting an attempt, and back off otherwise.
pub type RetryDelay {
  /// The provider's own `Retry-After`, read from the response headers. A
  /// scheduler maps it to a snooze: the provider chose the time, so no
  /// attempt is spent. (Not a scheduler's "retry after": that spends one.) LLM
  /// Wire does not cap it: bound it before sleeping or scheduling. A date
  /// in the past is a zero delay.
  ProviderDelay(Duration)
  /// The provider named no delay: choose a backoff. Also the delay of a
  /// failure that carried no response headers, such as a timeout.
  Backoff
}

// --- configuration -----------------------------------------------------------

/// Send to another base URL, such as a compatible server or a proxy. The
/// endpoint is checked by `prepare`.
pub fn with_endpoint(config: Config, endpoint: String) -> Config {
  config.with_adapter(
    config,
    adapter.with_endpoint(config.adapter(config), endpoint),
  )
}

/// Set one byte or count bound; see `llm_wire/limit` for every bound and
/// its default.
pub fn with_limit(config: Config, which: Limit, value: Int) -> Config {
  config.with_limits(config, limits.set(config.limits(config), which, value))
}

/// Bound the whole call, from the start of execution to the final event.
/// Default `After(duration.seconds(600))`.
pub fn with_call_timeout(config: Config, bound: Bound) -> Config {
  let timeouts = config.timeouts(config)
  config.with_timeouts(
    config,
    config.Timeouts(..timeouts, whole_call: to_ms(bound)),
  )
}

/// Bound the wait from the start of execution to the first progress event,
/// covering admission, the response head and hidden reasoning. Default
/// `After(duration.seconds(180))`.
pub fn with_first_token_timeout(config: Config, bound: Bound) -> Config {
  let timeouts = config.timeouts(config)
  config.with_timeouts(
    config,
    config.Timeouts(..timeouts, first_token: to_ms(bound)),
  )
}

/// Bound the gap between provider events after the first progress event.
/// Every event resets it, tool-argument deltas and pings included. Default
/// `After(duration.seconds(60))`.
pub fn with_idle_timeout(config: Config, bound: Bound) -> Config {
  let timeouts = config.timeouts(config)
  config.with_timeouts(
    config,
    config.Timeouts(..timeouts, idle_gap: to_ms(bound)),
  )
}

/// Choose whether a call to an unknown tool or with invalid arguments fails
/// the response (the default) or is reported in `NeedsTools.issues`.
pub fn with_tool_call_checks(config: Config, checks: ToolCallChecks) -> Config {
  config.with_checks(config, checks)
}

fn to_ms(bound: Bound) -> Option(Int) {
  case bound {
    Infinity -> None
    After(span) -> {
      let #(seconds, nanoseconds) = duration.to_seconds_and_nanoseconds(span)
      // Whole milliseconds, rounding a remainder away from zero, so a
      // positive duration stays positive.
      Some(seconds * 1000 + { nanoseconds + 999_999 } / 1_000_000)
    }
  }
}

// --- requests ----------------------------------------------------------------

/// A plain request: its `Answer.output` is the final text.
pub fn request(model: String, messages: List(Message)) -> Request(String) {
  call.request(
    adapter.Request(
      model:,
      messages:,
      max_tokens: None,
      temperature: None,
      top_p: None,
      stop_sequences: [],
      prompt_cache: None,
    ),
    [],
    call.Output(format: None, decode: fn(_, text, _) { Ok(text) }),
  )
}

/// Ask for structured output matching `codec`'s schema, named `name`. The
/// answer is validated and decoded; invalid output fails the call with
/// `error.InvalidOutput`.
pub fn with_output(
  request: Request(a),
  name: String,
  output: codec.Codec(o),
) -> Request(o) {
  let admitted = case codec.schema(output) {
    Error(_) -> Error("the output codec has no schema")
    Ok(schema) -> Ok(#(schema, contract.from_schema(schema)))
  }
  call.request(
    call.view(request),
    call.tools(request),
    call.Output(
      format: Some(#(name, admitted)),
      decode: fn(output_contract, text, max_bytes) {
        case output_contract {
          Some(output_contract) ->
            tool_def.decode_value(output_contract, output, text, max_bytes)
          // `prepare` refuses a request whose codec has no usable schema.
          None -> codec.decode_json(output, text) |> map_decode_error
        }
      },
    ),
  )
}

fn map_decode_error(
  result: Result(o, codec.DecodeError),
) -> Result(o, error.ValueFailure) {
  case result {
    Ok(value) -> Ok(value)
    Error(problem) -> Error(error.DecodeRejected(problem))
  }
}

pub fn with_tools(request: Request(o), tools: List(Tool)) -> Request(o) {
  call.with_tools(request, tools)
}

pub fn with_max_tokens(request: Request(o), max: Int) -> Request(o) {
  view(request, adapter.Request(..call.view(request), max_tokens: Some(max)))
}

pub fn with_temperature(request: Request(o), temperature: Float) -> Request(o) {
  view(
    request,
    adapter.Request(..call.view(request), temperature: Some(temperature)),
  )
}

pub fn with_top_p(request: Request(o), top_p: Float) -> Request(o) {
  view(request, adapter.Request(..call.view(request), top_p: Some(top_p)))
}

pub fn with_stop_sequences(
  request: Request(o),
  sequences: List(String),
) -> Request(o) {
  view(
    request,
    adapter.Request(..call.view(request), stop_sequences: sequences),
  )
}

/// Send OpenAI's `prompt_cache_key`. Other providers refuse it in
/// `prepare`.
pub fn with_openai_prompt_cache_key(
  request: Request(o),
  key: String,
) -> Request(o) {
  view(
    request,
    adapter.Request(
      ..call.view(request),
      prompt_cache: Some(adapter.OpenAiPromptCacheKey(key)),
    ),
  )
}

/// Send Gemini's `cachedContent` reference. Other providers refuse it in
/// `prepare`.
pub fn with_google_cached_content(
  request: Request(o),
  name: String,
) -> Request(o) {
  view(
    request,
    adapter.Request(
      ..call.view(request),
      prompt_cache: Some(adapter.GoogleCachedContent(name)),
    ),
  )
}

/// The request's conversation.
pub fn messages(request: Request(o)) -> List(Message) {
  call.view(request).messages
}

/// Append messages to the request's conversation.
pub fn append(request: Request(o), messages: List(Message)) -> Request(o) {
  view(
    request,
    adapter.Request(
      ..call.view(request),
      messages: list.append(call.view(request).messages, messages),
    ),
  )
}

pub fn model(request: Request(o)) -> String {
  call.view(request).model
}

pub fn tools(request: Request(o)) -> List(Tool) {
  call.tools(request)
}

fn view(request: Request(o), view: adapter.Request) -> Request(o) {
  call.with_view(request, view)
}

// --- messages ----------------------------------------------------------------

pub fn system(text: String) -> Message {
  message.System(text)
}

pub fn user(text: String) -> Message {
  message.User(text)
}

/// An assistant message the application wrote, without provider data.
pub fn assistant(text: String) -> Message {
  message.Assistant(message.AssistantTurn(
    provider: None,
    text:,
    calls: [],
    response_id: None,
    provider_data: None,
  ))
}

/// The result of `call`, for the request after a `NeedsTools` outcome.
pub fn tool_result(call: ToolCall, content: String) -> Message {
  message.ToolResult(call.id, content)
}

// --- execution ---------------------------------------------------------------

/// Admit and encode `request` for `config`, without I/O.
pub fn prepare(
  config: Config,
  request: Request(o),
) -> Result(Prepared(o), PrepareError) {
  case config.validate_timeouts(config.timeouts(config)) {
    Error(problem) -> Error(problem)
    Ok(Nil) -> {
      let output = case call.output(request).format {
        None -> Ok(None)
        Some(#(name, Ok(#(schema, output_contract)))) ->
          Ok(Some(#(name, schema, output_contract)))
        Some(#(_, Error(reason))) ->
          Error(error.UnsupportedSchema(error.Output, reason))
      }
      case output {
        Error(problem) -> Error(problem)
        Ok(output) ->
          case
            api.prepare(
              config.adapter(config),
              call.view(request),
              call.tools(request),
              option.map(output, fn(o) { #(o.0, o.1) }),
              config.limits(config),
            )
          {
            Error(problem) -> Error(problem)
            Ok(prepared) ->
              Ok(call.prepared(
                prepared,
                config,
                option.map(output, fn(o) { o.2 }),
                call.output(request).decode,
              ))
          }
      }
    }
  }
}

/// The JSON body `prepared` sends, for logs and tests. It never contains
/// headers or credentials.
pub fn request_json(prepared: Prepared(o)) -> String {
  api.request_json(call.prepared_call(prepared))
}

/// Execute the call and wait for its outcome.
pub fn run(
  client: http_gun.Client,
  prepared: Prepared(o),
) -> Result(Outcome(o), Failure) {
  case stream(client, prepared) {
    Ok(started) -> collect(started)
    Error(failure) -> Error(failure)
  }
}

/// Start the call. The calling process owns the stream: if it exits, the
/// call is cancelled and its HTTP stream released.
pub fn stream(
  client: http_gun.Client,
  prepared: Prepared(o),
) -> Result(Stream(o), Failure) {
  let provider = api.provider(call.prepared_call(prepared))
  let context =
    observe.Context(
      call: observe.new_call_id(),
      correlation: http_gun.correlation(client),
      provider: message.provider_name(provider),
    )
  observe.emit(context, telemetry.Started, telemetry.Accepted)
  let config = call.prepared_config(prepared)
  let setup =
    owner.Setup(
      context:,
      reducer: adapter.Reducer(fn(_) { Error(error.Stopped) }, fn() { None }),
      limits: config.limits(config),
      timeouts: config.timeouts(config),
      tools: api.tools(call.prepared_call(prepared)),
      checks: config.checks(config),
    )
  let max_bytes =
    int_min(
      config.limits(config).text_bytes_per_block_limit,
      config.limits(config).total_text_bytes_limit,
    )
  let contract = call.prepared_contract(prepared)
  let decode = call.prepared_decode(prepared)
  case http_client.open(client, call.prepared_call(prepared), setup) {
    Ok(source) ->
      Ok(
        call.stream(source, provider, fn(text) {
          decode(contract, text, max_bytes)
        }),
      )
    Error(Nil) -> Error(Failure(error.Stopped, NotSent, False, provider, None))
  }
}

fn int_min(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}

/// Wait for the stream's next event. The call's timers bound the wait.
pub fn next(stream: Stream(o)) -> Result(Event(o), ReadError) {
  read(stream, None)
}

/// Wait at most `wait` for the next event. `TimedOut` leaves the stream
/// readable.
pub fn next_within(
  stream: Stream(o),
  wait: Duration,
) -> Result(Event(o), ReadError) {
  let ms = case to_ms(After(wait)) {
    Some(ms) if ms > 0 -> ms
    _ -> 0
  }
  read(stream, Some(ms))
}

fn read(stream: Stream(o), wait: Option(Int)) -> Result(Event(o), ReadError) {
  case owner.next(call.source(stream), wait) {
    Ok(stream_types.NextProgress(progress)) -> Ok(Progress(progress))
    Ok(stream_types.StreamTerminal(terminal, usage)) ->
      Ok(Done(outcome(stream, terminal, usage)))
    Error(stream_types.StreamClosed) -> Error(StreamEnded)
    Error(stream_types.ConcurrentReadConflict) -> Error(ConcurrentRead)
    Error(stream_types.OwnerUnavailable) -> Error(OwnerGone)
    Error(stream_types.ReadTimeout) -> Error(TimedOut)
  }
}

fn outcome(
  stream: Stream(o),
  terminal: stream_types.TerminalOutcome,
  last_usage: Option(Usage),
) -> Result(Outcome(o), Failure) {
  let provider = call.provider(stream)
  let turn = fn(text, calls, response_id, provider_data) {
    message.AssistantTurn(
      provider: Some(provider),
      text:,
      calls:,
      response_id:,
      provider_data:,
    )
  }
  case terminal {
    stream_types.StreamFinished(stream_types.CompletedText(text), usage) ->
      case call.decode(stream, text) {
        Ok(output) -> Ok(Answer(output:, text:, usage:))
        Error(problem) ->
          Error(Failure(
            error.InvalidOutput(text, problem),
            Completed,
            True,
            provider,
            usage,
          ))
      }
    stream_types.StreamFinished(
      stream_types.CompletedToolCalls(text, calls, response_id, issues),
      usage,
    ) -> Ok(NeedsTools(turn(text, calls, response_id, None), issues, usage))
    stream_types.StreamFinished(
      stream_types.CompletedToolCallsWithData(
        text,
        calls,
        response_id,
        data,
        issues,
      ),
      usage,
    ) ->
      Ok(NeedsTools(turn(text, calls, response_id, Some(data)), issues, usage))
    stream_types.StreamFinished(stream_types.OutputLimited(text, calls), usage) ->
      Ok(OutputLimited(text, calls, usage))
    stream_types.StreamFinished(stream_types.Refused(reason), usage) ->
      Ok(Refused(reason, usage))
    stream_types.StreamFailed(problem, evidence) ->
      Error(Failure(
        problem,
        sent(evidence),
        evidence.semantic_progress_observed,
        provider,
        last_usage,
      ))
    stream_types.StreamCancelledLocally(evidence) ->
      Error(Failure(
        error.Cancelled,
        sent(evidence),
        evidence.semantic_progress_observed,
        provider,
        last_usage,
      ))
  }
}

fn sent(evidence: stream_types.RetryEvidence) -> Sent {
  case evidence.classification {
    stream_types.NoRequestSent -> NotSent
    stream_types.RequestMayHaveReachedProvider | stream_types.EffectUnknown ->
      MaybeSent
    stream_types.ResponseCompleted -> Completed
  }
}

/// Read the stream to its outcome, discarding progress.
pub fn collect(stream: Stream(o)) -> Result(Outcome(o), Failure) {
  case next(stream) {
    Ok(Progress(_)) -> collect(stream)
    Ok(Done(result)) -> result
    Error(_) ->
      Error(Failure(error.Stopped, MaybeSent, True, call.provider(stream), None))
  }
}

/// End the call early. Safe to call more than once.
pub fn close(stream: Stream(o)) -> CloseOutcome {
  case owner.close(call.source(stream)) {
    stream_types.ConsumerClosed -> Closed
    stream_types.AlreadyTerminal -> AlreadyEnded
  }
}

// --- failures ----------------------------------------------------------------

/// A one-line description of a failure for logs.
pub fn describe_failure(failure: Failure) -> String {
  error.describe(failure.error)
  <> " ("
  <> message.provider_name(failure.provider)
  <> ", "
  <> case failure.sent {
    NotSent -> "not sent"
    MaybeSent -> "maybe sent"
    Completed -> "completed"
  }
  <> ")"
}

/// Decide whether another attempt may help, from the failure alone.
///
/// HTTP Gun failures are classified by their `Kind`: unavailable, network
/// and timeout failures may help; refused destinations, invalid requests
/// and limits will not. HTTP statuses 408, 429, 500, 502, 503 and 504 (and
/// Anthropic's 529) may help. Provider error codes are matched exactly per
/// provider; prose is never parsed. The `delay` is `ProviderDelay` when the
/// provider sent a readable `Retry-After` (delay seconds or an HTTP date)
/// and `Backoff` otherwise. LLM Wire never retries by itself, and `MayHelp`
/// does not make a `MaybeSent` call free: it may have spent tokens.
///
/// ```gleam
/// case llm_wire.advise(failure) {
///   RetryAdvice(MayHelp, delay: ProviderDelay(wait)) -> snooze(wait)
///   RetryAdvice(MayHelp, delay: Backoff) -> retry_with_backoff()
///   RetryAdvice(_, _) -> give_up(llm_wire.describe_failure(failure))
/// }
/// ```
pub fn advise(failure: Failure) -> RetryAdvice {
  case failure.error {
    error.Http(http_failure) ->
      RetryAdvice(
        case http_error.kind(http_failure) {
          http_error.Unavailable | http_error.Network | http_error.TimedOut ->
            MayHelp
          http_error.InvalidInput
          | http_error.Refused
          | http_error.TooLarge
          | http_error.CancelledLocally
          | http_error.Misuse
          | http_error.Playback -> WillNotHelpUnchanged
        },
        delay(retry_after.from_headers(http_error.headers(http_failure))),
      )
    error.Status(code, _, after) ->
      RetryAdvice(assess_status(failure.provider, code), delay(after))
    error.Provider(Some(code), _) ->
      RetryAdvice(assess_code(failure.provider, code), Backoff)
    error.Provider(None, _) -> RetryAdvice(Unknown, Backoff)
    error.DeadlineExceeded(_) -> RetryAdvice(MayHelp, Backoff)
    error.LimitExceeded(..) | error.Cancelled ->
      RetryAdvice(WillNotHelpUnchanged, Backoff)
    error.Protocol(_) | error.InvalidOutput(..) | error.Stopped ->
      RetryAdvice(Unknown, Backoff)
  }
}

fn delay(after: Option(Duration)) -> RetryDelay {
  case after {
    Some(wait) -> ProviderDelay(wait)
    None -> Backoff
  }
}

fn assess_status(provider: Provider, status: Int) -> RetryProspect {
  case status {
    408 | 429 | 500 | 502 | 503 | 504 -> MayHelp
    400 | 401 | 403 | 404 | 405 | 406 | 410 | 413 | 415 | 422 | 501 | 505 ->
      WillNotHelpUnchanged
    529 ->
      case provider {
        message.Anthropic -> MayHelp
        _ -> Unknown
      }
    _ -> Unknown
  }
}

fn assess_code(provider: Provider, code: String) -> RetryProspect {
  case provider {
    message.OpenAI -> assess_openai_code(code)
    message.Anthropic -> assess_anthropic_code(code)
    message.Google -> assess_google_code(code)
    message.Custom(_) -> Unknown
  }
}

// Verified against the provider's error guide and response-error schema:
// https://developers.openai.com/api/docs/guides/error-codes
// https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_error.py
fn assess_openai_code(code: String) -> RetryProspect {
  case code {
    "server_error"
    | "rate_limit_exceeded"
    | "slow_down"
    | "server_is_overloaded" -> MayHelp
    "invalid_prompt"
    | "insufficient_quota"
    | "credit_balance_exhausted"
    | "organization_spend_limit_exceeded"
    | "project_spend_limit_exceeded"
    | "organization_usage_limit_exceeded" -> WillNotHelpUnchanged
    _ -> Unknown
  }
}

// https://platform.claude.com/docs/en/api/errors
fn assess_anthropic_code(code: String) -> RetryProspect {
  case code {
    "rate_limit_error" | "api_error" | "timeout_error" | "overloaded_error" ->
      MayHelp
    "invalid_request_error"
    | "authentication_error"
    | "billing_error"
    | "permission_error"
    | "not_found_error"
    | "request_too_large" -> WillNotHelpUnchanged
    _ -> Unknown
  }
}

// Canonical status strings retained by the GenerateContent adapter:
// https://ai.google.dev/gemini-api/docs/troubleshooting
// https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/api-errors
fn assess_google_code(code: String) -> RetryProspect {
  case code {
    "RESOURCE_EXHAUSTED" | "INTERNAL" | "UNAVAILABLE" | "DEADLINE_EXCEEDED" ->
      MayHelp
    "INVALID_ARGUMENT"
    | "FAILED_PRECONDITION"
    | "UNAUTHENTICATED"
    | "PERMISSION_DENIED"
    | "NOT_FOUND" -> WillNotHelpUnchanged
    _ -> Unknown
  }
}
