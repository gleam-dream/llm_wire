import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import json/blueprint/codec
import json/blueprint/parser
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

pub fn tool_name(raw: String) -> Result(ToolName, WireError) {
  let trimmed = string.trim(raw)
  case trimmed {
    "" -> Error(ProtocolError("tool_name cannot be empty"))
    _ -> Ok(ToolName(trimmed))
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

pub fn api_key_expose(key: ApiKey) -> String {
  let ApiKey(raw) = key
  raw
}

pub fn api_key_redacted(_key: ApiKey) -> String {
  "[REDACTED]"
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
}

/// Transport security selected while admitting an endpoint.
pub type TlsMode {
  Plaintext
  VerifySystem
  VerifyCaFile(path: String)
}

pub type ProviderConfig {
  OpenAIConfig(
    api_key: ApiKey,
    endpoint: Endpoint,
    organization: Option(String),
    project: Option(String),
  )
  AnthropicConfig(api_key: ApiKey, endpoint: Endpoint, version: Option(String))
}

pub type Limits {
  Limits(
    chunk_bytes_limit: Int,
    line_bytes_limit: Int,
    event_bytes_limit: Int,
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

pub fn new_limits(
  chunk_bytes_limit chunk_bytes_limit: Int,
  line_bytes_limit line_bytes_limit: Int,
  event_bytes_limit event_bytes_limit: Int,
  queue_count_limit queue_count_limit: Int,
  queue_bytes_limit queue_bytes_limit: Int,
  active_blocks_limit active_blocks_limit: Int,
  text_bytes_per_block_limit text_bytes_per_block_limit: Int,
  total_text_bytes_limit total_text_bytes_limit: Int,
  argument_bytes_per_call_limit argument_bytes_per_call_limit: Int,
  total_argument_bytes_limit total_argument_bytes_limit: Int,
  extension_bytes_limit extension_bytes_limit: Int,
  response_body_bytes_limit response_body_bytes_limit: Int,
) -> Result(Limits, WireError) {
  case
    chunk_bytes_limit > 0
    && line_bytes_limit > 0
    && event_bytes_limit > 0
    && queue_count_limit > 0
    && queue_bytes_limit > 0
    && active_blocks_limit > 0
    && text_bytes_per_block_limit > 0
    && total_text_bytes_limit > 0
    && argument_bytes_per_call_limit > 0
    && total_argument_bytes_limit > 0
    && extension_bytes_limit > 0
    && response_body_bytes_limit > 0
  {
    True ->
      Ok(Limits(
        chunk_bytes_limit: chunk_bytes_limit,
        line_bytes_limit: line_bytes_limit,
        event_bytes_limit: event_bytes_limit,
        queue_count_limit: queue_count_limit,
        queue_bytes_limit: queue_bytes_limit,
        active_blocks_limit: active_blocks_limit,
        text_bytes_per_block_limit: text_bytes_per_block_limit,
        total_text_bytes_limit: total_text_bytes_limit,
        argument_bytes_per_call_limit: argument_bytes_per_call_limit,
        total_argument_bytes_limit: total_argument_bytes_limit,
        extension_bytes_limit: extension_bytes_limit,
        response_body_bytes_limit: response_body_bytes_limit,
      ))
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

pub fn new_deadlines(
  overall_timeout_ms overall_timeout_ms: Int,
  idle_timeout_ms idle_timeout_ms: Int,
  read_timeout_ms read_timeout_ms: Int,
) -> Result(Deadlines, WireError) {
  case overall_timeout_ms > 0 && idle_timeout_ms > 0 && read_timeout_ms > 0 {
    True ->
      Ok(Deadlines(
        overall_timeout_ms: overall_timeout_ms,
        idle_timeout_ms: idle_timeout_ms,
        read_timeout_ms: read_timeout_ms,
      ))
    False ->
      Error(ConfigurationError("all deadline timeouts must be positive (> 0)"))
  }
}

pub fn openai_config(
  api_key: ApiKey,
  endpoint: Endpoint,
  organization: Option(String),
  project: Option(String),
) -> ProviderConfig {
  OpenAIConfig(api_key, endpoint, organization, project)
}

pub fn anthropic_config(
  api_key: ApiKey,
  endpoint: Endpoint,
  version: Option(String),
) -> ProviderConfig {
  AnthropicConfig(api_key, endpoint, version)
}

pub type ToolCall {
  ToolCall(id: CallId, name: ToolName, arguments_json: String)
}

pub type Message {
  SystemMessage(content: String)
  UserMessage(content: String)
  AssistantMessage(content: String)
  AssistantToolCalls(calls: List(ToolCall))
  ToolResultMessage(call_id: CallId, content: String)
}

pub opaque type ToolDefinition {
  ToolDefinition(
    name: ToolName,
    description: String,
    schema: codec.Schema,
    contract: runtime.RuntimeContract,
    decode_arguments: fn(runtime.ValidatedValue) -> Result(Nil, WireError),
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
                  Error(ProtocolError(
                    "Tool arguments failed native decode: "
                    <> string.inspect(error),
                  ))
              }
            }),
          )
      }
    Error(_) -> Error(PreparationError("Codec has no schema"))
  }
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

pub fn tool_definition_name(definition: ToolDefinition) -> String {
  tool_name_to_string(definition.name)
}

pub fn validate_tool_arguments(
  definition: ToolDefinition,
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
    False ->
      case parser.parse_value_from_string(parser.default_limits(), args_json) {
        Error(_) -> Error(ProtocolError("Invalid JSON in tool call arguments"))
        Ok(parsed) ->
          case runtime.validate(definition.contract, parsed) {
            Error(error) ->
              Error(ProtocolError(
                "Tool call arguments failed schema validation: "
                <> string.inspect(error),
              ))
            Ok(validated) -> definition.decode_arguments(validated)
          }
      }
  }
}

pub fn admit_tool_catalog(
  tools: List(ToolDefinition),
) -> Result(List(ToolDefinition), WireError) {
  list.fold(tools, Ok([]), fn(acc, tool) {
    case acc {
      Error(error) -> Error(error)
      Ok(admitted) -> {
        let name = tool_definition_name(tool)
        case
          list.any(admitted, fn(item) { tool_definition_name(item) == name })
        {
          True -> Error(PreparationError("Duplicate tool name: " <> name))
          False -> Ok(list.append(admitted, [tool]))
        }
      }
    }
  })
}

pub type ToolResult {
  ToolResult(call_id: CallId, content: String)
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

pub type Outcome {
  CompletedText(text: String)
  Refused(reason: String)
  CompletedToolCalls(
    text: String,
    calls: List(ToolCall),
    response_id: Option(String),
  )
  OutputLimited(partial_text: String, partial_calls: List(ToolCall))
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

pub type TerminalOutcome {
  StreamFinished(outcome: Outcome, usage: Option(Usage))
  StreamFailed(error: WireError, retry: RetryEvidence)
  StreamCancelledLocally(retry: RetryEvidence)
}

pub type ReadResult {
  NextProgress(StreamProgress)
  StreamTerminal(TerminalOutcome)
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
