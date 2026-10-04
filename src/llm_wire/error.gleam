//// Describes why a call failed (`Error`) or could not be prepared
//// (`PrepareError`).
////
//// A failed call returns an `llm_wire.Failure`, whose `error` field is an
//// `Error`. Most callers decide with `llm_wire.advise(failure)` and log with
//// `llm_wire.describe_failure(failure)`; branch on `Error` only for the
//// cases you handle differently:
////
//// ```gleam
//// case failure.error {
////   error.InvalidOutput(raw_output:, failure: reason) -> store(raw_output, reason)
////   error.Http(http_failure) -> log(http_error.describe(http_failure))
////   _ -> log(llm_wire.describe_failure(failure))
//// }
//// ```
////
//// `kind(error)` is a closed classification that never gains variants, for
//// a caller that wants an exhaustive `case`; `name(error)` is a stable
//// identifier for logs and stored records.
////
//// `Http` carries HTTP Gun's opaque `Failure`, so `http_gun/error.kind`,
//// `is_retryable`, `status` and `headers` apply to it directly.
////
//// `prepare` is pure, so its `PrepareError` never describes the network: it
//// names the setting, request field, schema or tool result that must
//// change. `Error`, `PrepareError` and their detail types may gain variants
//// in a minor release; match them with a `_` arm. Strings in variants are
//// diagnostics for people; branch on the variants, never on the text.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/time/duration.{type Duration}
import http_gun/error as http_error
import json/blueprint/codec
import json/blueprint/contract
import json/blueprint/value
import llm_wire/limit.{type Limit}

/// Why an executed call failed.
pub type Error {
  /// The HTTP exchange failed. The opaque `Failure` keeps HTTP Gun's
  /// `Kind`, evidence, status and response headers.
  Http(failure: http_error.Failure)
  /// The provider answered with a status other than 200. `body` is at most
  /// `limit.ErrorBodyBytes`; `retry_after` comes from a `Retry-After`
  /// header in seconds or as an HTTP date.
  Status(code: Int, body: String, retry_after: Option(Duration))
  /// The provider reported an error inside the stream.
  Provider(code: Option(String), message: String)
  /// The stream broke the provider's protocol. `detail` is diagnostic.
  Protocol(detail: String)
  /// A bound was exceeded. `limit` names the `llm_wire.with_limit` setting
  /// that raises it.
  LimitExceeded(limit: Limit, limit_value: Int, measured: Int)
  /// A timer expired; `timeout` names the `llm_wire.with_*_timeout` setter.
  DeadlineExceeded(timeout: Timeout)
  /// The caller closed the stream or cancelled the call.
  Cancelled
  /// The model's final text is not valid structured output.
  InvalidOutput(raw_output: String, failure: ValueFailure)
  /// The process that owned the call stopped before a result, for example
  /// because it could not start.
  Stopped
  /// The provider's safety system blocked the prompt or stopped the output.
  /// `reason` is the provider's own value: OpenAI's
  /// `incomplete_details.reason` (`"content_filter"`), Anthropic's
  /// `stop_reason` (`"refusal"`), Gemini's `finishReason` (`"SAFETY"`,
  /// `"RECITATION"`, `"BLOCKLIST"`, `"PROHIBITED_CONTENT"`, `"SPII"`,
  /// `"IMAGE_SAFETY"`, `"IMAGE_PROHIBITED_CONTENT"`) or
  /// `promptFeedback.blockReason`. Retrying the same request will not help.
  /// A model that declines in its own words is the outcome
  /// `llm_wire.Refused`, not this error.
  ContentFiltered(stage: FilterStage, reason: String)
}

/// Where a provider's content filter stopped a call.
pub type FilterStage {
  /// The prompt was blocked before generation (Gemini's
  /// `promptFeedback.blockReason`).
  InPrompt
  /// Generation stopped after it started.
  InOutput
}

/// A small, closed classification of `Error`. Unlike `Error`, it gains no
/// variants in a minor release, so a `case` on it needs no `_` arm. Branch
/// on it, decide retries with `llm_wire.advise`, and read `Error` for
/// detail.
pub type Kind {
  /// `Http` or `DeadlineExceeded`: the exchange did not complete.
  Transport
  /// `Status` or `Provider`: the provider answered with an error.
  ProviderError
  /// `ContentFiltered`: the provider's safety system stopped the call; the
  /// prompt must change.
  ContentPolicy
  /// `Protocol` or `InvalidOutput`: the response arrived but cannot be used.
  UnusableResponse
  /// `LimitExceeded`: a bound set with `llm_wire.with_limit` stopped the
  /// call.
  OverLimit
  /// `Cancelled` or `Stopped`: the call ended locally before a result.
  Ended
}

/// The three timers of a call.
pub type Timeout {
  /// From the start of execution to the final event. Default 600 s.
  WholeCall
  /// From the start of execution to the first progress event, covering
  /// admission, the response head and hidden reasoning. Default 180 s.
  FirstToken
  /// The longest gap between provider events after the first progress
  /// event. Every event resets it, including tool-argument deltas and
  /// pings. Default 60 s.
  IdleGap
}

/// Why a JSON value (structured output or tool arguments) was refused.
pub type ValueFailure {
  /// The text is not JSON within the parser's bounds.
  InvalidJson(value.ParseError)
  /// The JSON does not satisfy the schema.
  SchemaRejected(contract.ValidationError)
  /// The JSON satisfies the schema but the codec refused it.
  DecodeRejected(codec.DecodeError)
}

/// Why `llm_wire.prepare` refused a configuration or request.
pub type PrepareError {
  /// A configuration value is invalid. `reason` is diagnostic.
  InvalidSetting(setting: Setting, reason: String)
  /// A request field or message is invalid for this provider.
  InvalidRequest(problem: RequestProblem)
  /// A tool or output schema cannot be sent to this provider.
  UnsupportedSchema(location: SchemaLocation, reason: String)
  /// Tool results do not match the calls of the assistant turn before
  /// them.
  ToolResultMismatch(call_id: String, problem: ResultProblem)
  /// The request exceeds a bound before it is sent.
  RequestTooLarge(limit: Limit, limit_value: Int, measured: Int)
}

/// A configuration value `InvalidSetting` names.
pub type Setting {
  ApiKey
  Model
  Endpoint
  Header
  OutputName
  LimitSetting(limit: Limit)
  TimeoutSetting(timeout: Timeout)
}

/// What is wrong with a request.
pub type RequestProblem {
  MaxTokensNotPositive
  TemperatureOutOfRange
  TopPOutOfRange
  /// A prompt cache key or cached-content name is empty.
  EmptyPromptCache
  /// The prompt cache reference belongs to another provider.
  PromptCacheUnsupported
  StopSequencesUnsupported
  TooManyStopSequences(maximum: Int)
  /// This provider refuses remote image URLs; send inline image data.
  ImageUrlUnsupported
  DuplicateToolName(name: String)
  /// A call in the conversation has an empty id or a duplicate id.
  InvalidCallId(call_id: String)
  /// A call in the conversation names a tool outside the tool-name grammar.
  InvalidToolName(name: String)
  /// An assistant turn came from a different provider than this request.
  TurnFromOtherProvider
  /// An assistant turn's provider data is missing, malformed or disagrees
  /// with its text and calls. `reason` is diagnostic.
  InvalidProviderData(reason: String)
}

/// Where an unsupported schema was found.
pub type SchemaLocation {
  ToolInput(tool: String)
  Output
}

/// How tool results disagree with the calls they answer.
pub type ResultProblem {
  MissingResult
  DuplicateResult
  /// The result answers no call of the preceding assistant turn.
  UnknownCall
  /// The result follows no assistant turn with calls.
  NoPrecedingCalls
}

/// A one-line description for logs.
pub fn describe(error: Error) -> String {
  case error {
    Http(failure) -> "HTTP failure: " <> http_error.describe(failure)
    Status(code, _, _) ->
      "Provider answered with HTTP status " <> int.to_string(code)
    Provider(Some(code), message) ->
      "Provider error " <> code <> ": " <> message
    Provider(None, message) -> "Provider error: " <> message
    Protocol(detail) -> "Provider protocol violation: " <> detail
    LimitExceeded(limit, limit_value, measured) ->
      "Limit "
      <> limit.name(limit)
      <> " exceeded: "
      <> int.to_string(measured)
      <> " > "
      <> int.to_string(limit_value)
    DeadlineExceeded(timeout) -> timeout_name(timeout) <> " timeout expired"
    Cancelled -> "Call cancelled"
    InvalidOutput(_, failure) ->
      "Invalid structured output: " <> describe_value_failure(failure)
    Stopped -> "The call's owner process stopped before a result"
    ContentFiltered(InPrompt, reason) ->
      "Provider content filter blocked the prompt: " <> reason
    ContentFiltered(InOutput, reason) ->
      "Provider content filter stopped the output: " <> reason
  }
}

/// The closed classification of `error`.
pub fn kind(error: Error) -> Kind {
  case error {
    Http(_) | DeadlineExceeded(_) -> Transport
    Status(..) | Provider(..) -> ProviderError
    ContentFiltered(..) -> ContentPolicy
    Protocol(_) | InvalidOutput(..) -> UnusableResponse
    LimitExceeded(..) -> OverLimit
    Cancelled | Stopped -> Ended
  }
}

/// A stable snake_case name, such as `"content_policy"`.
pub fn kind_name(kind: Kind) -> String {
  case kind {
    Transport -> "transport"
    ProviderError -> "provider_error"
    ContentPolicy -> "content_policy"
    UnusableResponse -> "unusable_response"
    OverLimit -> "over_limit"
    Ended -> "ended"
  }
}

/// A stable identifier for logs and stored records, such as
/// `"limit_exceeded.total_text_bytes"` or `"deadline_exceeded.first_token"`.
pub fn name(error: Error) -> String {
  case error {
    Http(failure) -> "http." <> http_error.name(failure)
    Status(..) -> "status"
    Provider(..) -> "provider"
    Protocol(..) -> "protocol"
    LimitExceeded(limit:, ..) -> "limit_exceeded." <> limit.name(limit)
    DeadlineExceeded(timeout) -> "deadline_exceeded." <> timeout_name(timeout)
    Cancelled -> "cancelled"
    InvalidOutput(failure:, ..) ->
      "invalid_output." <> value_failure_name(failure)
    Stopped -> "stopped"
    ContentFiltered(InPrompt, _) -> "content_filtered.prompt"
    ContentFiltered(InOutput, _) -> "content_filtered.output"
  }
}

/// A stable snake_case name: `"whole_call"`, `"first_token"` or
/// `"idle_gap"`.
pub fn timeout_name(timeout: Timeout) -> String {
  case timeout {
    WholeCall -> "whole_call"
    FirstToken -> "first_token"
    IdleGap -> "idle_gap"
  }
}

/// A one-line description of a refused JSON value.
pub fn describe_value_failure(failure: ValueFailure) -> String {
  case failure {
    InvalidJson(error) -> "invalid JSON: " <> value.describe_parse_error(error)
    SchemaRejected(error) ->
      "schema validation failed: " <> contract.describe_validation_error(error)
    DecodeRejected(error) ->
      "decode failed: " <> codec.describe_decode_error(error)
  }
}

fn value_failure_name(failure: ValueFailure) -> String {
  case failure {
    InvalidJson(_) -> "invalid_json"
    SchemaRejected(_) -> "schema_rejected"
    DecodeRejected(_) -> "decode_rejected"
  }
}

/// A one-line description of a preparation error.
pub fn describe_prepare_error(error: PrepareError) -> String {
  case error {
    InvalidSetting(setting, reason) ->
      "Invalid " <> setting_name(setting) <> ": " <> reason
    InvalidRequest(problem) -> "Invalid request: " <> describe_problem(problem)
    UnsupportedSchema(location, reason) ->
      "Unsupported "
      <> case location {
        ToolInput(tool) -> "input schema of tool " <> tool
        Output -> "output schema"
      }
      <> ": "
      <> reason
    ToolResultMismatch(call_id, problem) ->
      case problem {
        MissingResult -> "Missing tool result for call " <> call_id
        DuplicateResult -> "Duplicate tool result for call " <> call_id
        UnknownCall -> "Tool result answers no preceding call: " <> call_id
        NoPrecedingCalls ->
          "Tool result follows no assistant turn with calls: " <> call_id
      }
    RequestTooLarge(limit, limit_value, measured) ->
      "Request exceeds "
      <> limit.name(limit)
      <> ": "
      <> int.to_string(measured)
      <> " > "
      <> int.to_string(limit_value)
  }
}

fn setting_name(setting: Setting) -> String {
  case setting {
    ApiKey -> "API key"
    Model -> "model"
    Endpoint -> "endpoint"
    Header -> "provider header"
    OutputName -> "output name"
    LimitSetting(limit) -> "limit " <> limit.name(limit)
    TimeoutSetting(timeout) -> timeout_name(timeout) <> " timeout"
  }
}

fn describe_problem(problem: RequestProblem) -> String {
  case problem {
    MaxTokensNotPositive -> "max_tokens must be positive"
    TemperatureOutOfRange -> "temperature must be between 0 and 2"
    TopPOutOfRange -> "top_p must be between 0 and 1"
    EmptyPromptCache -> "the prompt cache reference is empty"
    PromptCacheUnsupported ->
      "the prompt cache reference belongs to another provider"
    StopSequencesUnsupported -> "stop sequences are not supported"
    TooManyStopSequences(maximum) ->
      "at most " <> int.to_string(maximum) <> " stop sequences are accepted"
    ImageUrlUnsupported -> "image URLs are not supported; send inline data"
    DuplicateToolName(name) -> "duplicate tool name " <> name
    InvalidCallId(call_id) ->
      "invalid or duplicate call id \"" <> call_id <> "\""
    InvalidToolName(name) -> "invalid tool name \"" <> name <> "\""
    TurnFromOtherProvider -> "an assistant turn belongs to another provider"
    InvalidProviderData(reason) -> "invalid provider data: " <> reason
  }
}
