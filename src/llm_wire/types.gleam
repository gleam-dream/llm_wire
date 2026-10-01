import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import http_gun/error as http_error
import json/blueprint/codec
import json/blueprint/parser
import json/blueprint/parser_limits
import json/blueprint/runtime

pub opaque type ModelId {
  ModelId(String)
}

pub fn model_id(raw: String) -> Result(ModelId, WireError) {
  let trimmed = string.trim(raw)
  case trimmed {
    "" -> Error(ConfigurationError("model_id cannot be empty"))
    _ -> Ok(ModelId(trimmed))
  }
}

pub fn model_id_to_string(id: ModelId) -> String {
  let ModelId(raw) = id
  raw
}

pub opaque type CallId {
  CallId(String)
}

pub fn call_id(raw: String) -> Result(CallId, WireError) {
  let trimmed = string.trim(raw)
  case trimmed {
    "" -> Error(ProtocolError("call_id cannot be empty"))
    _ -> Ok(CallId(trimmed))
  }
}

pub fn call_id_to_string(id: CallId) -> String {
  let CallId(raw) = id
  raw
}

pub opaque type ToolName {
  ToolName(String)
}

/// Why a tool name falls outside the grammar every built-in provider accepts.
pub type ToolNameError {
  EmptyToolName
  /// The first character outside ASCII letters, digits, `_`, and `-`.
  InvalidToolNameCharacter(character: String)
  /// The name has more than 64 characters.
  ToolNameTooLong(length: Int)
}

const tool_name_max_length = 64

/// Admits a name matching `^[a-zA-Z0-9_-]{1,64}$`, the intersection of the
/// OpenAI, Anthropic, and Google tool-name rules. The name is not trimmed, so
/// the provider receives exactly the declared value.
pub fn tool_name(raw: String) -> Result(ToolName, ToolNameError) {
  case raw {
    "" -> Error(EmptyToolName)
    _ ->
      case
        list.find(string.to_graphemes(raw), fn(c) { !is_tool_name_char(c) })
      {
        Ok(character) -> Error(InvalidToolNameCharacter(character))
        Error(Nil) ->
          case string.byte_size(raw) > tool_name_max_length {
            True -> Error(ToolNameTooLong(string.byte_size(raw)))
            False -> Ok(ToolName(raw))
          }
      }
  }
}

/// Decoders admit provider-returned names with the same grammar; a name that
/// cannot be represented or replayed is a protocol violation of the response.
@internal
pub fn provider_tool_name(raw: String) -> Result(ToolName, WireError) {
  case tool_name(raw) {
    Ok(name) -> Ok(name)
    Error(error) ->
      Error(ProtocolError(
        "Provider returned an invalid tool name: " <> string.inspect(error),
      ))
  }
}

fn is_tool_name_char(grapheme: String) -> Bool {
  case <<grapheme:utf8>> {
    <<c>> ->
      { c >= 0x61 && c <= 0x7A }
      || { c >= 0x41 && c <= 0x5A }
      || { c >= 0x30 && c <= 0x39 }
      || c == 0x5F
      || c == 0x2D
    _ -> False
  }
}

pub fn tool_name_to_string(name: ToolName) -> String {
  let ToolName(raw) = name
  raw
}

pub opaque type ApiKey {
  ApiKey(String)
}

pub fn api_key(raw: String) -> Result(ApiKey, WireError) {
  let trimmed = string.trim(raw)
  case trimmed {
    "" -> Error(ConfigurationError("api_key cannot be empty"))
    _ -> Ok(ApiKey(trimmed))
  }
}

@internal
pub fn api_key_expose(key: ApiKey) -> String {
  let ApiKey(raw) = key
  raw
}

pub opaque type Endpoint {
  Endpoint(String)
}

pub fn endpoint(raw: String) -> Result(Endpoint, WireError) {
  let trimmed = string.trim(raw)
  case
    string.starts_with(trimmed, "http://")
    || string.starts_with(trimmed, "https://")
  {
    True -> Ok(Endpoint(trimmed))
    False ->
      Error(ConfigurationError("endpoint must start with http:// or https://"))
  }
}

pub fn endpoint_to_string(ep: Endpoint) -> String {
  let Endpoint(raw) = ep
  raw
}

pub type Provider {
  OpenAI
  Anthropic
  Google
  Custom(name: String)
}

pub type Limits {
  Limits(
    chunk_bytes_limit: Int,
    line_bytes_limit: Int,
    event_bytes_limit: Int,
    request_bytes_limit: Int,
    provider_metadata_bytes_limit: Int,
    queue_count_limit: Int,
    queue_bytes_limit: Int,
    active_blocks_limit: Int,
    text_bytes_per_block_limit: Int,
    total_text_bytes_limit: Int,
    argument_bytes_per_call_limit: Int,
    total_argument_bytes_limit: Int,
    extension_bytes_limit: Int,
    response_body_bytes_limit: Int,
  )
}

pub fn default_limits() -> Limits {
  Limits(
    chunk_bytes_limit: 65_536,
    line_bytes_limit: 16_384,
    event_bytes_limit: 1_048_576,
    request_bytes_limit: 1_048_576,
    provider_metadata_bytes_limit: 1_048_576,
    queue_count_limit: 500,
    queue_bytes_limit: 2_097_152,
    active_blocks_limit: 64,
    text_bytes_per_block_limit: 1_048_576,
    total_text_bytes_limit: 4_194_304,
    argument_bytes_per_call_limit: 1_048_576,
    total_argument_bytes_limit: 4_194_304,
    extension_bytes_limit: 16_384,
    response_body_bytes_limit: 8_388_608,
  )
}

@internal
pub fn validate_limits(limits: Limits) -> Result(Nil, WireError) {
  case
    limits.chunk_bytes_limit > 0
    && limits.line_bytes_limit > 0
    && limits.event_bytes_limit > 0
    && limits.request_bytes_limit > 0
    && limits.provider_metadata_bytes_limit > 0
    && limits.queue_count_limit > 0
    && limits.queue_bytes_limit > 0
    && limits.active_blocks_limit > 0
    && limits.text_bytes_per_block_limit > 0
    && limits.total_text_bytes_limit > 0
    && limits.argument_bytes_per_call_limit > 0
    && limits.total_argument_bytes_limit > 0
    && limits.extension_bytes_limit > 0
    && limits.response_body_bytes_limit > 0
  {
    True -> Ok(Nil)
    False ->
      Error(ConfigurationError("all limits must be positive integers (> 0)"))
  }
}

pub type DeadlineType {
  OverallDeadline
  IdleDeadline
  ReadDeadline
}

pub type Deadlines {
  Deadlines(overall_timeout_ms: Int, idle_timeout_ms: Int, read_timeout_ms: Int)
}

pub fn default_deadlines() -> Deadlines {
  Deadlines(
    overall_timeout_ms: 60_000,
    idle_timeout_ms: 15_000,
    read_timeout_ms: 5000,
  )
}

@internal
pub fn validate_deadlines(deadlines: Deadlines) -> Result(Nil, WireError) {
  case
    deadlines.overall_timeout_ms > 0
    && deadlines.idle_timeout_ms > 0
    && deadlines.read_timeout_ms > 0
  {
    True -> Ok(Nil)
    False ->
      Error(ConfigurationError("all deadline timeouts must be positive (> 0)"))
  }
}

pub type ToolCall {
  ToolCall(
    id: CallId,
    name: ToolName,
    arguments_json: String,
    provider_id: Option(String),
    provider_state: Option(String),
  )
}

/// Constructs an application-authored call without provider replay metadata.
/// Provider-originated calls retain their metadata in the full ToolCall record.
pub fn tool_call(
  id: CallId,
  name: ToolName,
  arguments_json: String,
) -> ToolCall {
  ToolCall(id, name, arguments_json, None, None)
}

pub type Content {
  TextContent(text: String)
  ImageUrlContent(url: String)
  InlineImageContent(mime_type: String, base64_data: String)
}

/// One completed provider tool response. This is message data only: it has no
/// configuration, conversation, codec, callback, or execution lifecycle.
/// Keep provider_data with this turn when supplying it in a later request.
pub type AssistantTurn {
  AssistantTurn(
    provider: Provider,
    text: String,
    calls: List(ToolCall),
    response_id: Option(String),
    provider_data: Option(String),
    issues: List(ToolCallIssue),
  )
}

pub type Message {
  SystemMessage(content: String)
  UserMessage(content: String)
  UserContent(parts: List(Content))
  AssistantMessage(content: String)
  AssistantContent(parts: List(Content))
  AssistantTurnMessage(turn: AssistantTurn)
  AssistantToolCalls(calls: List(ToolCall))
  AssistantToolCallsWithText(text: String, calls: List(ToolCall))
  ToolResultMessage(call_id: CallId, content: String)
}

pub opaque type ToolDefinition {
  ToolDefinition(
    name: ToolName,
    description: String,
    schema: codec.Schema,
    contract: runtime.RuntimeContract,
    decode_arguments: fn(runtime.ValidatedValue) -> Result(Nil, String),
  )
}

pub fn tool_from_codec(
  name: ToolName,
  description: String,
  input_codec: codec.Codec(a),
) -> Result(ToolDefinition, WireError) {
  case codec.schema(input_codec) {
    Ok(schema) ->
      case runtime.from_schema(schema) {
        Error(error) ->
          Error(PreparationError(
            "Invalid tool schema: " <> string.inspect(error),
          ))
        Ok(contract) ->
          Ok(
            ToolDefinition(name, description, schema, contract, fn(validated) {
              case runtime.decode(input_codec, validated) {
                Ok(_) -> Ok(Nil)
                Error(error) ->
                  Error(
                    "Tool arguments failed native decode: "
                    <> string.inspect(error),
                  )
              }
            }),
          )
      }
    Error(_) -> Error(PreparationError("Codec has no schema"))
  }
}

/// Admit a schema-only tool without inventing an application value type.
/// The selected provider projects or rejects its schema during preparation.
pub fn tool_from_contract(
  name: ToolName,
  description: String,
  contract: runtime.RuntimeContract,
) -> ToolDefinition {
  ToolDefinition(name, description, runtime.schema(contract), contract, fn(_) {
    Ok(Nil)
  })
}

pub fn tool_name_of(definition: ToolDefinition) -> ToolName {
  definition.name
}

pub fn tool_description(definition: ToolDefinition) -> String {
  definition.description
}

pub fn tool_schema(definition: ToolDefinition) -> codec.Schema {
  definition.schema
}

@internal
pub fn validate_tool_arguments(
  definition: ToolDefinition,
  max_bytes: Int,
  args_json: String,
) -> Result(Nil, WireError) {
  case check_argument_bytes(max_bytes, args_json) {
    Error(error) -> Error(error)
    Ok(Nil) ->
      case check_tool_arguments(definition, max_bytes, args_json) {
        Ok(Nil) -> Ok(Nil)
        Error(reason) -> Error(ProtocolError(reason))
      }
  }
}

/// The per-call argument bound. Exceeding it fails the whole response.
@internal
pub fn check_argument_bytes(
  max_bytes: Int,
  args_json: String,
) -> Result(Nil, WireError) {
  let bytes = string.byte_size(args_json)
  case bytes > max_bytes {
    True ->
      Error(ResourceLimitExceeded(
        "argument_bytes_per_call_limit",
        max_bytes,
        bytes,
      ))
    False -> Ok(Nil)
  }
}

/// Parses, schema-validates, and natively decodes arguments that are already
/// within `max_bytes`. The error explains the failure for the model.
@internal
pub fn check_tool_arguments(
  definition: ToolDefinition,
  max_bytes: Int,
  args_json: String,
) -> Result(Nil, String) {
  let assert Ok(parser_bounds) =
    parser_limits.default() |> parser_limits.with_max_bytes(max_bytes)
  case parser.parse_value_from_string(parser_bounds, args_json) {
    Error(_) -> Error("Invalid JSON in tool call arguments")
    Ok(parsed) ->
      case runtime.validate(definition.contract, parsed) {
        Error(error) ->
          Error(
            "Tool call arguments failed schema validation: "
            <> string.inspect(error),
          )
        Ok(validated) -> definition.decode_arguments(validated)
      }
  }
}

@internal
pub fn admit_tool_catalog(
  tools: List(ToolDefinition),
) -> Result(List(ToolDefinition), WireError) {
  list.fold(tools, Ok([]), fn(acc, tool) {
    case acc {
      Error(error) -> Error(error)
      Ok(admitted) -> {
        let name = tool_name_to_string(tool_name_of(tool))
        case
          list.any(admitted, fn(item) {
            tool_name_to_string(tool_name_of(item)) == name
          })
        {
          True -> Error(PreparationError("Duplicate tool name: " <> name))
          False -> Ok(list.append(admitted, [tool]))
        }
      }
    }
  })
}

/// How a finished tool-call response treats a call that names a tool outside
/// the request's catalog or carries arguments that fail its schema.
pub type ToolCallChecks {
  /// Fail the whole response with `ProtocolError`. This is the default.
  RejectInvalidToolCalls
  /// Return every call and report each failing one as a `ToolCallIssue`. The
  /// caller answers such calls with a `ToolResult` like any other call, and
  /// the call replays on the next request without rewriting. Providers that
  /// take an object (Anthropic, Google) receive argument text that is not a
  /// JSON object as `{"unparsed_arguments": text}`.
  ReportInvalidToolCalls
}

/// Why one returned call cannot be dispatched as declared. Bounds, duplicate
/// call IDs, and names outside the tool-name grammar still fail the response.
pub type ToolCallIssue {
  /// The call names a tool the request did not declare.
  UnknownTool(call_id: CallId)
  /// The arguments are not JSON, fail the schema, or fail native decoding.
  InvalidArguments(call_id: CallId, reason: String)
}

pub type ToolResult {
  ToolResult(call_id: CallId, content: String)
}

pub type PromptCache {
  OpenAiPromptCacheKey(key: String)
  GoogleCachedContent(name: String)
}

pub type Request {
  Request(
    model: ModelId,
    messages: List(Message),
    tools: List(ToolDefinition),
    max_tokens: Option(Int),
    temperature: Option(Float),
    top_p: Option(Float),
    stop_sequences: List(String),
    prompt_cache: Option(PromptCache),
  )
}

pub fn new_request(model: ModelId, messages: List(Message)) -> Request {
  Request(
    model: model,
    messages: messages,
    tools: [],
    max_tokens: None,
    temperature: None,
    top_p: None,
    stop_sequences: [],
    prompt_cache: None,
  )
}

pub fn with_tools(req: Request, tools: List(ToolDefinition)) -> Request {
  Request(..req, tools: tools)
}

pub fn with_max_tokens(req: Request, max: Int) -> Request {
  Request(..req, max_tokens: Some(max))
}

pub fn with_temperature(req: Request, temp: Float) -> Request {
  Request(..req, temperature: Some(temp))
}

pub fn with_top_p(req: Request, top_p: Float) -> Request {
  Request(..req, top_p: Some(top_p))
}

pub fn with_stop_sequences(req: Request, seqs: List(String)) -> Request {
  Request(..req, stop_sequences: seqs)
}

pub fn with_prompt_cache(req: Request, cache: PromptCache) -> Request {
  Request(..req, prompt_cache: Some(cache))
}

pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int, total_tokens: Int)
}

pub type StreamProgress {
  TextDelta(block_id: String, text: String)
  RefusalDelta(block_id: String, text: String)
  ReasoningDelta(block_id: String, text: String)
  ProviderExtension(provider: String, event_name: String)
  UsageUpdate(usage: Usage)
}

pub type RetryClassification {
  NoRequestSent
  RequestMayHaveReachedProvider
  EffectUnknown
}

pub type RetryEvidence {
  RetryEvidence(
    classification: RetryClassification,
    response_bytes_observed: Bool,
    semantic_progress_observed: Bool,
  )
}

@internal
pub fn initial_retry_evidence() -> RetryEvidence {
  RetryEvidence(
    classification: NoRequestSent,
    response_bytes_observed: False,
    semantic_progress_observed: False,
  )
}

pub type WireError {
  ConfigurationError(reason: String)
  PreparationError(reason: String)
  TransportError(reason: String)
  /// Typed HTTP failure; diagnostic strings are never used as categories.
  HttpFailure(reason: http_error.Reason)
  HttpStatusError(status_code: Int, body: String, retry_hint: Option(RetryHint))
  ProviderError(code: Option(String), message: String)
  ProtocolError(reason: String)
  ResourceLimitExceeded(
    limit_name: String,
    limit_value: Int,
    measured_value: Int,
  )
  DeadlineExceeded(deadline_type: DeadlineType)
  CancelledLocally
  OutputValidationError(reason: String)
}

pub type RetryHint {
  RetryDelaySeconds(seconds: Int)
  /// Preserves an HTTP-date or unknown Retry-After value for caller parsing.
  RetryHeaderValue(value: String)
}

pub type ReadError {
  StreamClosed
  ConcurrentReadConflict
  OwnerUnavailable
  ReadTimeout
}

pub type CloseOutcome {
  ConsumerClosed
  ProviderCancellationConfirmed
  AlreadyTerminal
}
