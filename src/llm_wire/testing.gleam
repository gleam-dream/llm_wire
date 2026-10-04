//// Scripted LLM replies for tests, offline through HTTP Gun's scripted
//// client.
////
//// Describe a reply with `text`, `tool_calls`, `refusal`, `output_limited`,
//// `content_filtered` or `prompt_blocked`, pair it with a prepared call with
//// `exchange`, and give the exchanges to an `http_gun/testing` client. The
//// call then runs the ordinary `llm_wire.run` path:
////
//// ```gleam
//// import http_gun/config as http_config
//// import http_gun/testing as http_testing
//// import llm_wire
//// import llm_wire/testing
////
//// let request = llm_wire.request("m", [llm_wire.user("Hi")])
//// let assert Ok(prepared) = llm_wire.prepare(testing.config(), request)
//// let script =
////   http_testing.script([testing.exchange(prepared, testing.text("Hello"))])
//// let assert Ok(client) = http_testing.playback(script, http_config.default())
//// let assert Ok(llm_wire.Answer(text: "Hello", ..)) =
////   llm_wire.run(client, prepared)
//// ```
////
//// `config()` selects a provider-neutral scripted wire. To test code that
//// talks to a built-in provider, keep its configuration: `exchange` lowers
//// the reply into the prepared provider's wire, so no test writes the
//// provider's server-sent events by hand. `events(chunks)` sends chunks
//// exactly as given, for a custom provider's wire.
////
//// A provider's failures are scripted the same way. `rate_limited`,
//// `overloaded` and `http_status` write the error status and body of a
//// built-in provider, `interrupted` cuts a reply off, `invalid_output` is a
//// final text no schema accepts, and `with_retry_after` adds the
//// `Retry-After` header to an exchange:
////
//// ```gleam
//// let limited =
////   testing.exchange(prepared, testing.rate_limited(message.OpenAI))
////   |> testing.with_retry_after(duration.seconds(2))
//// ```
////
//// A fake HTTP server serves a reply without unwrapping it:
//// `http_response(message.OpenAI, reply)` is a `gleam/http` response. A
//// server that sends one chunk per event reads `status`, `chunks` and
//// `is_interrupted` of `events_for(provider, reply)` instead. To feed code
//// that takes a `llm_wire.Failure`, build one with `failure` instead of
//// running a call.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http/response.{type Response as HttpResponse}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration.{type Duration}
import http_gun/error as http_error
import http_gun/testing as http_testing
import llm_wire
import llm_wire/error
import llm_wire/internal/adapter
import llm_wire/internal/api
import llm_wire/internal/call
import llm_wire/internal/config
import llm_wire/internal/ids
import llm_wire/message.{type Provider, type Usage}
import llm_wire/provider

/// One scripted HTTP reply: a stream of server-sent events, or an error
/// status. Build it with `text`, `tool_calls`, `refusal`, `output_limited`,
/// `content_filtered`, `prompt_blocked`, the failure builders or `events`;
/// serve it with `exchange` or `http_response`.
///
/// A reply is in the provider-neutral scripted wire until `events_for`
/// lowers it into a built-in provider's wire. A lowered reply, and one
/// given as is with `events`, stays in its wire: `events_for` leaves it
/// unchanged.
pub opaque type Reply {
  Stream(wire: Wire, chunks: List(String), ending: Ending)
  Status(code: Int, body: String)
}

type Wire {
  /// The scripted wire, which `events_for` can lower.
  Scripted
  /// A provider's own wire.
  Native
}

type Ending {
  /// The stream ends normally after its chunks.
  Ends
  /// The connection drops after the chunks, before the end.
  CutOff
}

/// A tool call the scripted provider returns. Build it with `tool_call`.
pub opaque type ScriptedCall {
  ScriptedCall(id: String, name: String, arguments_json: String)
}

/// A tool call for `tool_calls`. Its fields are wire values: the runtime
/// admits them exactly as it admits a real provider's call.
pub fn tool_call(
  id id: String,
  name name: String,
  arguments_json arguments_json: String,
) -> ScriptedCall {
  ScriptedCall(id:, name:, arguments_json:)
}

/// A final text answer. Non-empty text streams as one `TextDelta`.
pub fn text(text: String) -> Reply {
  scripted(list.append(text_events(text), [end_event("complete", "")]))
}

/// Tool calls, optionally after assistant text, awaiting results.
pub fn tool_calls(text: String, calls: List(ScriptedCall)) -> Reply {
  scripted(
    list.flatten([
      text_events(text),
      list.map(calls, call_event),
      [end_event("tool_calls", "")],
    ]),
  )
}

/// The model declines in its own words; the call answers
/// `llm_wire.Refused(reason:, ..)`. Only OpenAI's wire and the scripted wire
/// carry a model's refusal: `events_for` panics for Anthropic and Google,
/// whose only refusal on the wire is a safety stop (`content_filtered`).
pub fn refusal(reason: String) -> Reply {
  scripted([end_event("refusal", reason)])
}

/// Output cut off at the token limit after `partial_text`.
pub fn output_limited(partial_text: String) -> Reply {
  scripted(list.append(text_events(partial_text), [end_event("length", "")]))
}

/// The provider's content filter stops the output after `partial_text`.
/// The call fails with `error.ContentFiltered(error.InOutput, reason)` and
/// `sent: Completed`, where `reason` is the wire's own value: OpenAI's
/// `response.incomplete` with `incomplete_details.reason`
/// `"content_filter"`, Anthropic's `stop_reason` `"refusal"`, Gemini's
/// `finishReason` `"SAFETY"`, and `"content_filter"` on the scripted wire.
pub fn content_filtered(partial_text: String) -> Reply {
  scripted(
    list.append(text_events(partial_text), [
      end_event("filtered", "content_filter"),
    ]),
  )
}

/// The provider's content filter blocks the prompt before generation. The
/// call fails with `error.ContentFiltered(error.InPrompt, reason)`: Gemini's
/// `promptFeedback.blockReason` `"SAFETY"`, and `"content_filter"` on the
/// scripted wire. OpenAI and Anthropic reject such a prompt with an error
/// status instead (`http_status`), so `events_for` panics for them.
pub fn prompt_blocked() -> Reply {
  scripted([end_event("blocked", "content_filter")])
}

/// A final text that is not valid JSON. A plain call answers with it; a
/// structured call fails with `error.InvalidOutput` carrying this text.
pub fn invalid_output() -> Reply {
  text("this is not valid structured output")
}

/// A successful stream of exactly these chunks, one per read, then the end
/// of the stream. Chunks may split events anywhere. Use it for a wire the
/// builders do not write, such as a custom provider's or a provider event
/// with fields the builders leave out; `events_for` leaves it unchanged.
pub fn events(chunks: List(String)) -> Reply {
  Stream(Native, chunks, Ends)
}

fn scripted(chunks: List(String)) -> Reply {
  Stream(Scripted, chunks, Ends)
}

/// The connection drops after the reply's content, before its end, so the
/// call fails with an `error.Http` transport failure and `sent: MaybeSent`.
/// Apply it before `events_for`, which then also drops the provider's
/// terminal events. A reply from `events` keeps every chunk; a `Status`
/// reply is unchanged.
pub fn interrupted(reply: Reply) -> Reply {
  case reply {
    Stream(Scripted, chunks, _) -> Stream(Scripted, drop_end(chunks), CutOff)
    Stream(Native, chunks, _) -> Stream(Native, chunks, CutOff)
    Status(..) -> reply
  }
}

/// The HTTP status a server sends for `reply`: 200 for a stream.
pub fn status(reply: Reply) -> Int {
  case reply {
    Stream(..) -> 200
    Status(code, _) -> code
  }
}

/// The body chunks a server sends for `reply`, in order: one per event for
/// a stream (lower it first with `events_for` for a built-in provider), the
/// whole body for an error status.
pub fn chunks(reply: Reply) -> List(String) {
  case reply {
    Stream(_, chunks, _) -> chunks
    Status(_, body) -> [body]
  }
}

/// Whether a server must drop the connection after `chunks(reply)` instead
/// of ending the response: true after `interrupted`.
pub fn is_interrupted(reply: Reply) -> Bool {
  case reply {
    Stream(_, _, CutOff) -> True
    Stream(_, _, Ends) | Status(..) -> False
  }
}

fn drop_end(chunks: List(String)) -> List(String) {
  case list.reverse(chunks) {
    [last, ..rest] ->
      case string.starts_with(last, "event: end\n") {
        True -> list.reverse(rest)
        False -> chunks
      }
    [] -> chunks
  }
}

/// HTTP 429 with `provider`'s rate-limit error body. The call fails with
/// `error.Status(429, ..)`. Add the header with `with_retry_after`.
pub fn rate_limited(provider: Provider) -> Reply {
  http_status(provider, 429, "Rate limit reached")
}

/// `provider`'s overload error: HTTP 529 on Anthropic and 503 on every other
/// wire.
pub fn overloaded(provider: Provider) -> Reply {
  case provider {
    message.Anthropic -> http_status(provider, 529, "Overloaded")
    _ -> http_status(provider, 503, "The service is overloaded")
  }
}

/// An error `status` whose body carries `message`, shaped as `provider`
/// shapes its errors (a `Custom` provider gets the bare message, so
/// `http_status(message.Custom("scripted"), 503, "busy")` sends `busy` as
/// is). The call fails with `error.Status(status, ..)`.
pub fn http_status(provider: Provider, status: Int, message: String) -> Reply {
  Status(status, error_body(provider, status, message))
}

/// Add `Retry-After: seconds` to a fake server's `http_response`, rounding a
/// fraction up, so `advise` answers `ProviderDelay(delay)`. For a scripted
/// exchange, use `with_retry_after`.
pub fn with_retry_after_header(
  http: HttpResponse(String),
  delay: Duration,
) -> HttpResponse(String) {
  response.set_header(http, "retry-after", whole_seconds(delay))
}

/// Answer with `Retry-After: seconds`, rounding a fraction up. Use it on an
/// exchange of an error reply. An exchange that fails before a response is
/// unchanged.
pub fn with_retry_after(
  exchange: http_testing.Exchange,
  delay: Duration,
) -> http_testing.Exchange {
  case http_testing.reply(exchange) {
    http_testing.Respond(http, ending) ->
      http_testing.exchange(
        http_testing.request(exchange),
        http_testing.Respond(
          response.set_header(http, "retry-after", whole_seconds(delay)),
          ending,
        ),
      )
    http_testing.Reject(_) -> exchange
  }
}

fn whole_seconds(delay: Duration) -> String {
  let #(seconds, nanos) = duration.to_seconds_and_nanoseconds(delay)
  let seconds = case nanos > 0 {
    True -> seconds + 1
    False -> seconds
  }
  int.to_string(int.max(seconds, 0))
}

/// A `llm_wire.Failure` for `error` from `provider`, as a failed call would
/// return it, without running a call. `sent` follows the error: `NotSent`
/// for an HTTP Gun failure that sent nothing, `Completed` for a status, a
/// provider error or invalid output, `MaybeSent` otherwise. There is no
/// partial output and no usage; change a field with a record update:
/// `llm_wire.Failure(..testing.failure(p, e), partial_output: True)`.
pub fn failure(provider: Provider, error: error.Error) -> llm_wire.Failure {
  llm_wire.Failure(
    error:,
    sent: case error {
      error.Http(failure) ->
        case http_error.evidence(failure) {
          http_error.NotSent -> llm_wire.NotSent
          http_error.MaybeSent -> llm_wire.MaybeSent
        }
      error.Status(..)
      | error.Provider(..)
      | error.InvalidOutput(..)
      | error.ContentFiltered(..) -> llm_wire.Completed
      error.Protocol(_)
      | error.LimitExceeded(..)
      | error.DeadlineExceeded(_)
      | error.Cancelled
      | error.Stopped -> llm_wire.MaybeSent
    },
    partial_output: False,
    provider:,
    usage: None,
  )
}

/// `reply` as `provider` would send it, for a fake HTTP server: a
/// `gleam/http` response with the whole body in one string. A stream gets
/// status 200 and `text/event-stream`; an error status keeps its status,
/// and its body is `application/json` when it starts with `{`, else
/// `text/plain`. A server that must cut an interrupted reply off
/// (`is_interrupted`) does so itself; here it is the chunks so far.
pub fn http_response(provider: Provider, reply: Reply) -> HttpResponse(String) {
  case events_for(provider, reply) {
    Stream(_, chunks, _) ->
      response.new(200)
      |> response.set_header("content-type", "text/event-stream")
      |> response.set_body(string.concat(chunks))
    Status(code, body) ->
      response.new(code)
      |> response.set_header(
        "content-type",
        case string.starts_with(body, "{") {
          True -> "application/json"
          False -> "text/plain"
        },
      )
      |> response.set_body(body)
  }
}

fn error_body(provider: Provider, status: Int, message: String) -> String {
  case provider {
    message.Custom(_) -> message
    message.OpenAI ->
      json.object([
        #(
          "error",
          json.object([
            #("message", json.string(message)),
            #("type", json.string(openai_type(status))),
            #("param", json.null()),
            #("code", json.nullable(openai_code(status), json.string)),
          ]),
        ),
      ])
      |> json.to_string
    message.Anthropic ->
      json.object([
        #("type", json.string("error")),
        #(
          "error",
          json.object([
            #("type", json.string(anthropic_type(status))),
            #("message", json.string(message)),
          ]),
        ),
      ])
      |> json.to_string
    message.Google ->
      json.object([
        #(
          "error",
          json.object([
            #("code", json.int(status)),
            #("message", json.string(message)),
            #("status", json.string(google_status(status))),
          ]),
        ),
      ])
      |> json.to_string
  }
}

fn openai_type(status: Int) -> String {
  case status {
    429 -> "requests"
    status if status >= 500 -> "server_error"
    _ -> "invalid_request_error"
  }
}

fn openai_code(status: Int) -> Option(String) {
  case status {
    429 -> Some("rate_limit_exceeded")
    401 -> Some("invalid_api_key")
    _ -> None
  }
}

fn anthropic_type(status: Int) -> String {
  case status {
    400 -> "invalid_request_error"
    401 -> "authentication_error"
    402 -> "billing_error"
    403 -> "permission_error"
    404 -> "not_found_error"
    413 -> "request_too_large"
    429 -> "rate_limit_error"
    504 -> "timeout_error"
    529 -> "overloaded_error"
    _ -> "api_error"
  }
}

fn google_status(status: Int) -> String {
  case status {
    400 -> "INVALID_ARGUMENT"
    401 -> "UNAUTHENTICATED"
    403 -> "PERMISSION_DENIED"
    404 -> "NOT_FOUND"
    429 -> "RESOURCE_EXHAUSTED"
    500 -> "INTERNAL"
    503 -> "UNAVAILABLE"
    504 -> "DEADLINE_EXCEEDED"
    _ -> "UNKNOWN"
  }
}

/// The provider's in-band error event arrives after the reply's content: the
/// stream starts, `reply` streams, then the wire's own error event carries
/// `code` (OpenAI's `error.code`, Anthropic's `error.type`, Google's
/// `error.status`) and `message`. The call fails with
/// `error.Provider(Some(code), message)`, `sent: Completed` and the
/// partial output. The result is already in `provider`'s wire, like
/// `events_for`'s. Pass the reply before lowering; a lowered reply, one
/// from `events` and a `Status` reply are unchanged.
pub fn stream_error(
  provider: Provider,
  reply: Reply,
  code: String,
  message: String,
) -> Reply {
  with_closing_event(provider, reply, error_event(provider, code, message))
}

/// OpenAI's `response.failed` event after the reply's content: the stream
/// ends with the response object's `status: "failed"` and its `error` object
/// carrying `code` and `message`. The call fails like
/// `stream_error(message.OpenAI, ..)`, with `error.Provider(Some(code),
/// message)`. Like `stream_error`, the result is already in the OpenAI wire.
pub fn response_failed(reply: Reply, code: String, message: String) -> Reply {
  with_closing_event(message.OpenAI, reply, failed_event(code, message))
}

fn with_closing_event(
  provider: Provider,
  reply: Reply,
  closing: String,
) -> Reply {
  case reply {
    Stream(Scripted, _, _) -> {
      let lowered = events_for(provider, interrupted(reply))
      let wire = case provider {
        message.Custom(_) -> Scripted
        _ -> Native
      }
      Stream(wire, list.append(chunks(lowered), [closing]), Ends)
    }
    Stream(Native, _, _) | Status(..) -> reply
  }
}

fn failed_event(code: String, message: String) -> String {
  sse_event(
    "response.failed",
    json.object([
      #("type", json.string("response.failed")),
      #(
        "response",
        json.object([
          #("id", json.string("resp_scripted")),
          #("object", json.string("response")),
          #("status", json.string("failed")),
          #(
            "error",
            json.object([
              #("code", json.string(code)),
              #("message", json.string(message)),
            ]),
          ),
          #("incomplete_details", json.null()),
        ]),
      ),
    ]),
  )
}

fn error_event(provider: Provider, code: String, message: String) -> String {
  case provider {
    message.OpenAI ->
      sse_event(
        "error",
        json.object([
          #("type", json.string("error")),
          #("code", json.string(code)),
          #("message", json.string(message)),
          #(
            "error",
            json.object([
              #("code", json.string(code)),
              #("message", json.string(message)),
            ]),
          ),
        ]),
      )
    message.Anthropic ->
      sse_event(
        "error",
        json.object([
          #("type", json.string("error")),
          #(
            "error",
            json.object([
              #("type", json.string(code)),
              #("message", json.string(message)),
            ]),
          ),
        ]),
      )
    message.Google ->
      "data: "
      <> json.to_string(
        json.object([
          #(
            "error",
            json.object([
              #("code", json.int(google_code(code))),
              #("message", json.string(message)),
              #("status", json.string(code)),
            ]),
          ),
        ]),
      )
      <> "\n\n"
    message.Custom(_) ->
      sse_event(
        "error",
        json.object([
          #("code", json.string(code)),
          #("message", json.string(message)),
        ]),
      )
  }
}

fn google_code(status: String) -> Int {
  case status {
    "INVALID_ARGUMENT" -> 400
    "UNAUTHENTICATED" -> 401
    "PERMISSION_DENIED" -> 403
    "NOT_FOUND" -> 404
    "RESOURCE_EXHAUSTED" -> 429
    "UNAVAILABLE" -> 503
    "DEADLINE_EXCEEDED" -> 504
    _ -> 500
  }
}

/// Report `usage` with the reply. Apply it before `events_for`; a lowered
/// reply, one from `events` and a `Status` reply are unchanged.
pub fn with_usage(reply: Reply, usage: Usage) -> Reply {
  let event =
    sse_event(
      "usage",
      json.object([
        #("input_tokens", json.int(usage.input_tokens)),
        #("output_tokens", json.int(usage.output_tokens)),
        #("total_tokens", json.int(usage.total_tokens)),
      ]),
    )
  case reply {
    Stream(Scripted, chunks, ending) ->
      Stream(Scripted, [event, ..chunks], ending)
    Stream(Native, _, _) | Status(..) -> reply
  }
}

/// One finite HTTP Gun exchange answering `prepared` with `reply`, lowered
/// into the wire of `prepared`'s provider as `events_for` lowers it.
/// Recorded requests drop HTTP Gun's credential headers.
pub fn exchange(
  prepared: llm_wire.Prepared(o),
  reply: Reply,
) -> http_testing.Exchange {
  let provider =
    adapter.provider(config.adapter(call.prepared_config(prepared)))
  http_testing.exchange(
    api.http_request(call.prepared_call(prepared)),
    http_reply(events_for(provider, reply)),
  )
}

/// The configuration of the provider-neutral scripted wire.
pub fn config() -> llm_wire.Config {
  provider.new(
    message.Custom("scripted"),
    "https://scripted.llm-wire.invalid",
    encode_request,
    fn() {
      provider.reducer(
        Turn(text: "", calls: [], usage: None, terminal: None),
        step,
        fn(state: Turn) { state.terminal },
      )
    },
  )
  |> provider.config
}

fn http_reply(reply: Reply) -> http_testing.Reply {
  let ending = case is_interrupted(reply) {
    True ->
      http_testing.Aborted(http_error.new(
        http_error.RequestFailed(http_error.PeerClosed),
        http_error.MaybeSent,
      ))
    False -> http_testing.Finished([])
  }
  http_testing.Respond(
    response.new(status(reply))
      |> response.set_header("content-type", "text/event-stream")
      |> response.set_body(list.map(chunks(reply), bit_array.from_string)),
    ending,
  )
}

// --- scripted wire -----------------------------------------------------------

fn text_events(text: String) -> List(String) {
  case text {
    "" -> []
    _ -> [sse_event("text", json.object([#("text", json.string(text))]))]
  }
}

fn call_event(call: ScriptedCall) -> String {
  sse_event(
    "tool_call",
    json.object([
      #("id", json.string(call.id)),
      #("name", json.string(call.name)),
      #("arguments", json.string(call.arguments_json)),
    ]),
  )
}

fn end_event(stop: String, reason: String) -> String {
  sse_event(
    "end",
    json.object([#("stop", json.string(stop)), #("reason", json.string(reason))]),
  )
}

fn sse_event(name: String, data: json.Json) -> String {
  "event: " <> name <> "\ndata: " <> json.to_string(data) <> "\n\n"
}

type Turn {
  Turn(
    text: String,
    calls: List(message.ToolCall),
    usage: Option(Usage),
    terminal: Option(adapter.Terminal),
  )
}

fn encode_request(
  request: adapter.Request,
  tools: List(adapter.ProjectedTool),
  format: Option(adapter.OutputFormat),
) -> Result(adapter.Encoded, error.PrepareError) {
  let body =
    json.object([
      #("model", json.string(request.model)),
      #("messages", json.array(request.messages, encode_message)),
      #(
        "tools",
        json.array(tools, fn(tool) {
          json.object([
            #("name", json.string(tool.name)),
            #("description", json.string(tool.description)),
            #("schema", tool.schema),
          ])
        }),
      ),
      #(
        "output",
        json.nullable(format, fn(format) {
          json.object([
            #("name", json.string(format.name)),
            #("schema", format.schema),
          ])
        }),
      ),
    ])
  Ok(adapter.Encoded("/scripted", json.to_string(body)))
}

fn encode_message(msg: message.Message) -> json.Json {
  case msg {
    message.System(content) -> role_text("system", content)
    message.User(content) -> role_text("user", content)
    message.UserParts(parts) -> role_parts("user", parts)
    message.AssistantParts(parts) -> role_parts("assistant", parts)
    message.Assistant(turn) ->
      case turn.calls {
        [] -> role_text("assistant", turn.text)
        calls -> assistant_calls(turn.text, calls)
      }
    message.ToolResult(call_id, content) ->
      json.object([
        #("role", json.string("tool")),
        #("call_id", json.string(call_id)),
        #("content", json.string(content)),
      ])
  }
}

fn role_text(role: String, content: String) -> json.Json {
  json.object([#("role", json.string(role)), #("content", json.string(content))])
}

fn role_parts(role: String, parts: List(message.Content)) -> json.Json {
  json.object([
    #("role", json.string(role)),
    #(
      "parts",
      json.array(parts, fn(part) {
        case part {
          message.TextPart(text) -> json.object([#("text", json.string(text))])
          message.ImageUrlPart(url) ->
            json.object([#("image_url", json.string(url))])
          message.InlineImagePart(mime_type, data) ->
            json.object([
              #("mime_type", json.string(mime_type)),
              #("data", json.string(data)),
            ])
        }
      }),
    ),
  ])
}

fn assistant_calls(text: String, calls: List(message.ToolCall)) -> json.Json {
  json.object([
    #("role", json.string("assistant")),
    #("content", json.string(text)),
    #(
      "calls",
      json.array(calls, fn(call) {
        json.object([
          #("id", json.string(call.id)),
          #("name", json.string(call.name)),
          #("arguments", json.string(call.arguments_json)),
        ])
      }),
    ),
  ])
}

fn step(
  turn: Turn,
  event: adapter.Event,
) -> Result(#(Turn, List(message.Progress)), error.Error) {
  case turn.terminal, event.event {
    Some(_), _ -> Error(error.Protocol("Scripted event after end"))
    None, Some("text") -> {
      use text <- parse(event.data, decode.at(["text"], decode.string))
      Ok(
        #(Turn(..turn, text: turn.text <> text), [message.TextDelta("0", text)]),
      )
    }
    None, Some("tool_call") -> {
      use #(raw_id, raw_name, arguments) <- parse(event.data, call_decoder())
      use id <- result.try(ids.call_id(raw_id))
      use name <- result.try(ids.provider_tool_name(raw_name))
      Ok(
        #(
          Turn(..turn, calls: [
            message.tool_call(id, name, arguments),
            ..turn.calls
          ]),
          [
            message.ToolArgumentsDelta(id, arguments),
          ],
        ),
      )
    }
    None, Some("usage") -> {
      use usage <- parse(event.data, usage_decoder())
      Ok(#(Turn(..turn, usage: Some(usage)), [message.UsageUpdate(usage)]))
    }
    None, Some("error") -> {
      use #(code, reason) <- parse(event.data, error_decoder())
      Ok(
        #(
          Turn(
            ..turn,
            terminal: Some(adapter.Failed(
              error.Provider(Some(code), reason),
              turn.usage,
            )),
          ),
          [],
        ),
      )
    }
    None, Some("end") -> {
      use #(stop, reason) <- parse(event.data, end_decoder())
      let calls = list.reverse(turn.calls)
      let terminal = case stop, calls {
        "complete", [] -> Ok(adapter.Text(turn.text, turn.usage))
        "tool_calls", [_, ..] ->
          Ok(adapter.ToolCalls(turn.text, calls, None, None, turn.usage))
        "refusal", [] -> Ok(adapter.Refusal(reason, turn.usage))
        "length", _ -> Ok(adapter.OutputLimited(turn.text, calls, turn.usage))
        "filtered", _ ->
          Ok(adapter.Failed(
            error.ContentFiltered(error.InOutput, reason),
            turn.usage,
          ))
        "blocked", [] ->
          Ok(adapter.Failed(
            error.ContentFiltered(error.InPrompt, reason),
            turn.usage,
          ))
        _, _ ->
          Error(error.Protocol(
            "Scripted end does not match its calls: "
            <> stop
            <> " with "
            <> int.to_string(list.length(calls))
            <> " calls",
          ))
      }
      use terminal <- result.try(terminal)
      Ok(#(Turn(..turn, terminal: Some(terminal)), []))
    }
    None, other ->
      Error(error.Protocol(
        "Unknown scripted event: " <> option.unwrap(other, "<unnamed>"),
      ))
  }
}

fn call_decoder() -> decode.Decoder(#(String, String, String)) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use arguments <- decode.field("arguments", decode.string)
  decode.success(#(id, name, arguments))
}

fn usage_decoder() -> decode.Decoder(Usage) {
  use input <- decode.field("input_tokens", decode.int)
  use output <- decode.field("output_tokens", decode.int)
  use total <- decode.field("total_tokens", decode.int)
  decode.success(message.Usage(input, output, total))
}

fn error_decoder() -> decode.Decoder(#(String, String)) {
  use code <- decode.field("code", decode.string)
  use reason <- decode.field("message", decode.string)
  decode.success(#(code, reason))
}

fn end_decoder() -> decode.Decoder(#(String, String)) {
  use stop <- decode.field("stop", decode.string)
  use reason <- decode.field("reason", decode.string)
  decode.success(#(stop, reason))
}

fn parse(
  data: String,
  decoder: decode.Decoder(a),
  next: fn(a) -> Result(b, error.Error),
) -> Result(b, error.Error) {
  case json.parse(data, decoder) {
    Ok(value) -> next(value)
    Error(_) -> Error(error.Protocol("Malformed scripted event: " <> data))
  }
}

// --- built-in wires ----------------------------------------------------------

/// The semantic content of a scripted reply.
type Script {
  Script(
    text: String,
    calls: List(ScriptedCall),
    usage: Option(Usage),
    stop: String,
    reason: String,
  )
}

/// Lower a scripted reply into the server-sent events of a built-in
/// provider's wire, for a fake server that serves a provider's real
/// configuration (`exchange` lowers by itself). Each event becomes one
/// chunk. A reply already in a wire (lowered, or from `events`), a `Status`
/// reply and a `Custom` provider leave it unchanged.
///
/// The provider's reducer shapes some values: Gemini re-encodes call
/// arguments, which must be a JSON object (other text is sent as
/// `{"unparsed_arguments": text}`); Anthropic always reports usage.
/// `refusal` panics on Anthropic and Google and `prompt_blocked` on OpenAI
/// and Anthropic, whose wires do not carry them.
pub fn events_for(provider: Provider, reply: Reply) -> Reply {
  case reply, provider {
    Status(..), _ | Stream(Native, _, _), _ | _, message.Custom(_) -> reply
    Stream(Scripted, chunks, ending), _ ->
      Stream(Native, lower(provider, chunks), ending)
  }
}

fn lower(provider: Provider, chunks: List(String)) -> List(String) {
  let script = read_script(string.concat(chunks))
  let events = case provider {
    message.OpenAI -> openai_events(script)
    message.Anthropic -> anthropic_events(script)
    message.Google -> google_events(script)
    message.Custom(_) -> chunks
  }
  // Without an end event the reply was cut off: drop the wire's terminal.
  case script.stop, provider {
    "", message.OpenAI -> list.take(events, list.length(events) - 1)
    "", message.Anthropic -> list.take(events, list.length(events) - 2)
    "", message.Google ->
      list.map(events, string.replace(_, "\"finishReason\":\"STOP\",", ""))
    _, _ -> events
  }
}

fn read_script(raw: String) -> Script {
  let empty = Script(text: "", calls: [], usage: None, stop: "", reason: "")
  string.split(raw, "\n\n")
  |> list.fold(empty, fn(script, frame) {
    let #(name, data) =
      string.split(frame, "\n")
      |> list.fold(#("", ""), fn(acc, line) {
        case line {
          "event: " <> name -> #(name, acc.1)
          "data: " <> data -> #(acc.0, data)
          _ -> acc
        }
      })
    case name {
      "text" ->
        case json.parse(data, decode.at(["text"], decode.string)) {
          Ok(text) -> Script(..script, text: script.text <> text)
          Error(_) -> script
        }
      "tool_call" ->
        case json.parse(data, call_decoder()) {
          Ok(#(id, name, arguments)) ->
            Script(
              ..script,
              calls: list.append(script.calls, [
                ScriptedCall(id, name, arguments),
              ]),
            )
          Error(_) -> script
        }
      "usage" ->
        case json.parse(data, usage_decoder()) {
          Ok(usage) -> Script(..script, usage: Some(usage))
          Error(_) -> script
        }
      "end" ->
        case json.parse(data, end_decoder()) {
          Ok(#(stop, reason)) -> Script(..script, stop:, reason:)
          Error(_) -> script
        }
      _ -> script
    }
  })
}

fn event(name: String, data: json.Json) -> String {
  "event: " <> name <> "\ndata: " <> json.to_string(data) <> "\n\n"
}

fn openai_events(script: Script) -> List(String) {
  let text_item = case script.stop, script.text {
    "refusal", _ ->
      message_item(0, "msg_0", "response.refusal.delta", script.reason)
    _, "" -> []
    _, text -> message_item(0, "msg_0", "response.output_text.delta", text)
  }
  let offset = list.length(text_item) / 3
  let calls =
    list.index_map(script.calls, fn(call, index) {
      let at = offset + index
      let item = "fc_" <> int.to_string(at)
      [
        event(
          "response.output_item.added",
          json.object([
            #("output_index", json.int(at)),
            #(
              "item",
              json.object([
                #("id", json.string(item)),
                #("type", json.string("function_call")),
                #("call_id", json.string(call.id)),
                #("name", json.string(call.name)),
              ]),
            ),
          ]),
        ),
        event(
          "response.function_call_arguments.delta",
          json.object([
            #("output_index", json.int(at)),
            #("item_id", json.string(item)),
            #("delta", json.string(call.arguments_json)),
          ]),
        ),
        event(
          "response.output_item.done",
          json.object([
            #("output_index", json.int(at)),
            #("item", json.object([#("id", json.string(item))])),
          ]),
        ),
      ]
    })
    |> list.flatten
  // An incomplete response ends with `response.incomplete`, whose
  // `incomplete_details.reason` names the limit or the content filter.
  let #(name, status, incomplete) = case script.stop {
    "length" -> #(
      "response.incomplete",
      "incomplete",
      Some("max_output_tokens"),
    )
    "filtered" -> #("response.incomplete", "incomplete", Some("content_filter"))
    "blocked" -> unsupported(message.OpenAI, "prompt_blocked")
    _ -> #("response.completed", "completed", None)
  }
  let completed =
    event(
      name,
      json.object([
        #("type", json.string(name)),
        #(
          "response",
          json.object([
            #("id", json.string("resp_scripted")),
            #("status", json.string(status)),
            #(
              "incomplete_details",
              json.nullable(incomplete, fn(reason) {
                json.object([#("reason", json.string(reason))])
              }),
            ),
            #("usage", json.nullable(script.usage, usage_json)),
          ]),
        ),
      ]),
    )
  list.flatten([text_item, calls, [completed]])
}

fn message_item(
  index: Int,
  item: String,
  delta_event: String,
  text: String,
) -> List(String) {
  let at = #("output_index", json.int(index))
  [
    event(
      "response.output_item.added",
      json.object([
        at,
        #(
          "item",
          json.object([
            #("id", json.string(item)),
            #("type", json.string("message")),
          ]),
        ),
      ]),
    ),
    event(
      delta_event,
      json.object([
        at,
        #("item_id", json.string(item)),
        #("delta", json.string(text)),
      ]),
    ),
    event(
      "response.output_item.done",
      json.object([
        at,
        #(
          "item",
          json.object([
            #("id", json.string(item)),
            #("type", json.string("message")),
          ]),
        ),
      ]),
    ),
  ]
}

fn usage_json(usage: Usage) -> json.Json {
  json.object([
    #("input_tokens", json.int(usage.input_tokens)),
    #("output_tokens", json.int(usage.output_tokens)),
    #("total_tokens", json.int(usage.total_tokens)),
  ])
}

fn anthropic_events(script: Script) -> List(String) {
  let #(input, output) = case script.usage {
    Some(usage) -> #(usage.input_tokens, usage.output_tokens)
    None -> #(0, 0)
  }
  let text = case script.stop {
    "refusal" -> unsupported(message.Anthropic, "refusal")
    "blocked" -> unsupported(message.Anthropic, "prompt_blocked")
    _ -> script.text
  }
  let text_blocks = case text {
    "" -> []
    _ -> [
      block_start(
        0,
        json.object([#("type", json.string("text")), #("text", json.string(""))]),
      ),
      block_delta(
        0,
        json.object([
          #("type", json.string("text_delta")),
          #("text", json.string(text)),
        ]),
      ),
      block_stop(0),
    ]
  }
  let offset = case text {
    "" -> 0
    _ -> 1
  }
  let call_blocks =
    list.index_map(script.calls, fn(call, index) {
      let at = offset + index
      [
        block_start(
          at,
          json.object([
            #("type", json.string("tool_use")),
            #("id", json.string(call.id)),
            #("name", json.string(call.name)),
          ]),
        ),
        block_delta(
          at,
          json.object([
            #("type", json.string("input_json_delta")),
            #("partial_json", json.string(call.arguments_json)),
          ]),
        ),
        block_stop(at),
      ]
    })
    |> list.flatten
  let stop_reason = case script.stop {
    "tool_calls" -> "tool_use"
    "length" -> "max_tokens"
    "filtered" -> "refusal"
    _ -> "end_turn"
  }
  list.flatten([
    [
      event(
        "message_start",
        json.object([
          #("type", json.string("message_start")),
          #(
            "message",
            json.object([
              #("id", json.string("msg_scripted")),
              #("type", json.string("message")),
              #("role", json.string("assistant")),
              #(
                "usage",
                json.object([
                  #("input_tokens", json.int(input)),
                  #("output_tokens", json.int(0)),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    ],
    text_blocks,
    call_blocks,
    [
      event(
        "message_delta",
        json.object([
          #("type", json.string("message_delta")),
          #("delta", json.object([#("stop_reason", json.string(stop_reason))])),
          #("usage", json.object([#("output_tokens", json.int(output))])),
        ]),
      ),
      event(
        "message_stop",
        json.object([#("type", json.string("message_stop"))]),
      ),
    ],
  ])
}

fn block_start(index: Int, block: json.Json) -> String {
  event(
    "content_block_start",
    json.object([
      #("type", json.string("content_block_start")),
      #("index", json.int(index)),
      #("content_block", block),
    ]),
  )
}

fn block_delta(index: Int, delta: json.Json) -> String {
  event(
    "content_block_delta",
    json.object([
      #("type", json.string("content_block_delta")),
      #("index", json.int(index)),
      #("delta", delta),
    ]),
  )
}

fn block_stop(index: Int) -> String {
  event(
    "content_block_stop",
    json.object([
      #("type", json.string("content_block_stop")),
      #("index", json.int(index)),
    ]),
  )
}

fn google_events(script: Script) -> List(String) {
  let usage_field = case script.usage {
    Some(usage) ->
      ",\"usageMetadata\":"
      <> json.to_string(
        json.object([
          #("promptTokenCount", json.int(usage.input_tokens)),
          #("candidatesTokenCount", json.int(usage.output_tokens)),
          #("totalTokenCount", json.int(usage.total_tokens)),
        ]),
      )
    None -> ""
  }
  case script.stop {
    "refusal" -> unsupported(message.Google, "refusal")
    "blocked" -> [
      "data: {\"promptFeedback\":"
      <> json.to_string(json.object([#("blockReason", json.string("SAFETY"))]))
      <> usage_field
      <> "}\n\n",
    ]
    _ -> {
      let text_parts = case script.text {
        "" -> []
        text -> [json.to_string(json.object([#("text", json.string(text))]))]
      }
      // Gemini arguments are a JSON object, spliced verbatim.
      let call_parts =
        list.map(script.calls, fn(call) {
          "{\"functionCall\":{\"name\":"
          <> json.to_string(json.string(call.name))
          <> ",\"id\":"
          <> json.to_string(json.string(call.id))
          <> ",\"args\":"
          <> arguments_object(call.arguments_json)
          <> "}}"
        })
      let finish = case script.stop {
        "length" -> "MAX_TOKENS"
        "filtered" -> "SAFETY"
        _ -> "STOP"
      }
      [
        "data: {\"responseId\":\"resp_scripted\",\"candidates\":[{\"finishReason\":\""
        <> finish
        <> "\",\"content\":{\"role\":\"model\",\"parts\":["
        <> string.join(list.append(text_parts, call_parts), ",")
        <> "]}}]"
        <> usage_field
        <> "}\n\n",
      ]
    }
  }
}

fn unsupported(provider: Provider, builder: String) -> a {
  panic as {
    "llm_wire/testing: "
    <> message.provider_name(provider)
    <> "'s wire has no `"
    <> builder
    <> "`; see the builder's documentation"
  }
}

fn arguments_object(raw: String) -> String {
  case json.parse(raw, decode.dict(decode.string, decode.dynamic)) {
    Ok(_) -> raw
    Error(_) ->
      json.to_string(json.object([#("unparsed_arguments", json.string(raw))]))
  }
}
