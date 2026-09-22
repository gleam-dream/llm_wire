import gleam/list
import gleam/option.{type Option, None}
import llm_wire/api
import llm_wire/owner
import llm_wire/pool
import llm_wire/runtime
import llm_wire/types

pub type ModelId =
  types.ModelId

pub const model_id = types.model_id

pub const model_id_to_string = types.model_id_to_string

pub type CallId =
  types.CallId

pub const call_id = types.call_id

pub const call_id_to_string = types.call_id_to_string

pub type ToolName =
  types.ToolName

pub const tool_name = types.tool_name

pub const tool_name_to_string = types.tool_name_to_string

pub type ApiKey =
  types.ApiKey

pub const api_key = types.api_key

pub const api_key_redacted = types.api_key_redacted

pub type Endpoint =
  types.Endpoint

pub const endpoint = types.endpoint

pub const endpoint_to_string = types.endpoint_to_string

pub type Provider {
  OpenAI
  Anthropic
  Google
}

pub type ProviderConfig =
  types.ProviderConfig

pub const openai_config = types.openai_config

pub const anthropic_config = types.anthropic_config

pub const google_config = types.google_config

pub type Request =
  types.Request

pub fn new_request(model: ModelId, messages: List(Message)) -> Request {
  types.new_request(model, list.map(messages, to_types_message))
}

pub const with_tools = types.with_tools

pub const with_max_tokens = types.with_max_tokens

pub const with_temperature = types.with_temperature

pub const with_top_p = types.with_top_p

pub const with_stop_sequences = types.with_stop_sequences

pub type PromptCache {
  OpenAiPromptCacheKey(key: String)
  GoogleCachedContent(name: String)
}

pub fn with_prompt_cache(req: Request, cache: PromptCache) -> Request {
  types.with_prompt_cache(req, to_types_prompt_cache(cache))
}

pub type PreparedCall =
  api.PreparedCall

pub const prepare = api.prepare

pub fn prepared_provider(prepared: PreparedCall) -> Provider {
  case api.prepared_provider(prepared) {
    types.OpenAI -> OpenAI
    types.Anthropic -> Anthropic
    types.Google -> Google
  }
}

pub const prepared_path = api.prepared_path

pub const prepared_request_json = api.prepared_request_json

pub const stream = runtime.stream

pub fn run(
  prepared: PreparedCall,
  limits: Limits,
  deadlines: Deadlines,
) -> Result(RunResult, WireError) {
  case runtime.run(prepared, limits, deadlines) {
    Error(error) -> Error(error)
    Ok(api.RunText(text, usage)) -> Ok(RunText(text, usage))
    Ok(api.RunToolCalls(calls, continuation, usage)) ->
      Ok(RunToolCalls(
        list.map(calls, from_types_tool_call),
        continuation,
        usage,
      ))
    Ok(api.RunOutputLimited(text, calls, usage)) ->
      Ok(RunOutputLimited(text, list.map(calls, from_types_tool_call), usage))
    Ok(api.RunRefusal(reason)) -> Ok(RunRefusal(reason))
  }
}

pub type Pool =
  pool.Pool

pub type PoolConfig =
  pool.PoolConfig

pub type PoolInfo =
  pool.PoolInfo

pub const default_pool_config = pool.default_pool_config

pub const start_pool = pool.start

pub const stop_pool = pool.stop

pub const pool_info = pool.info

pub const stream_with_pool = runtime.stream_with_pool

pub fn run_with_pool(
  pool: Pool,
  prepared: PreparedCall,
  limits: Limits,
  deadlines: Deadlines,
) -> Result(RunResult, WireError) {
  case runtime.run_with_pool(pool, prepared, limits, deadlines) {
    Error(error) -> Error(error)
    Ok(api.RunText(text, usage)) -> Ok(RunText(text, usage))
    Ok(api.RunToolCalls(calls, continuation, usage)) ->
      Ok(RunToolCalls(
        list.map(calls, from_types_tool_call),
        continuation,
        usage,
      ))
    Ok(api.RunOutputLimited(text, calls, usage)) ->
      Ok(RunOutputLimited(text, list.map(calls, from_types_tool_call), usage))
    Ok(api.RunRefusal(reason)) -> Ok(RunRefusal(reason))
  }
}

pub fn prepare_continue(
  prepared: PreparedCall,
  continuation: Continuation,
  results: List(ToolResult),
  limits: Limits,
) -> Result(PreparedCall, WireError) {
  api.prepare_continue(
    prepared,
    continuation,
    list.map(results, to_types_tool_result),
    limits,
  )
}

pub type PreparedStructuredCall(output) =
  api.PreparedStructuredCall(output)

pub type StructuredRunResult(output) {
  StructuredValue(output: output, raw_json: String, usage: Option(types.Usage))
  StructuredNeedsTools(
    calls: List(ToolCall),
    continuation: Continuation,
    usage: Option(types.Usage),
  )
  StructuredOutputLimited(
    partial_text: String,
    partial_calls: List(ToolCall),
    usage: Option(types.Usage),
  )
  StructuredRefusal(reason: String)
}

pub const prepare_structured = api.prepare_structured

pub fn prepare_structured_continue(
  prepared: PreparedStructuredCall(output),
  continuation: Continuation,
  results: List(ToolResult),
  limits: Limits,
) -> Result(PreparedStructuredCall(output), WireError) {
  api.prepare_structured_continue(
    prepared,
    continuation,
    list.map(results, to_types_tool_result),
    limits,
  )
}

pub const stream_structured = runtime.stream_structured

pub fn run_structured(
  prepared: PreparedStructuredCall(output),
  limits: Limits,
  deadlines: Deadlines,
) -> Result(StructuredRunResult(output), WireError) {
  case runtime.run_structured(prepared, limits, deadlines) {
    Error(error) -> Error(error)
    Ok(api.StructuredValue(output, raw_json, usage)) ->
      Ok(StructuredValue(output, raw_json, usage))
    Ok(api.StructuredNeedsTools(calls, continuation, usage)) ->
      Ok(StructuredNeedsTools(
        list.map(calls, from_types_tool_call),
        continuation,
        usage,
      ))
    Ok(api.StructuredOutputLimited(text, calls, usage)) ->
      Ok(StructuredOutputLimited(
        text,
        list.map(calls, from_types_tool_call),
        usage,
      ))
    Ok(api.StructuredRefusal(reason)) -> Ok(StructuredRefusal(reason))
  }
}

pub const decode_structured_output = api.decode_structured_output

pub const structured_request_json = api.structured_request_json

pub type Stream =
  owner.Stream

pub const next = api.next

pub const close = api.close

pub type Limits =
  types.Limits

pub const new_limits = types.new_limits

pub const default_limits = types.default_limits

pub type DeadlineType =
  types.DeadlineType

pub type Deadlines =
  types.Deadlines

pub const new_deadlines = types.new_deadlines

pub const default_deadlines = types.default_deadlines

pub type Message {
  SystemMessage(content: String)
  UserMessage(content: String)
  UserContent(parts: List(Content))
  AssistantMessage(content: String)
  AssistantContent(parts: List(Content))
  AssistantToolCalls(calls: List(ToolCall))
  ToolResultMessage(call_id: CallId, content: String)
}

pub type Content {
  TextContent(text: String)
  ImageUrlContent(url: String)
  InlineImageContent(mime_type: String, base64_data: String)
}

pub type ToolResult {
  ToolResult(call_id: CallId, content: String)
}

pub type Continuation =
  api.Continuation

pub const continuation_response_id = api.continuation_response_id

pub type RunResult {
  RunText(text: String, usage: Option(types.Usage))
  RunToolCalls(
    calls: List(ToolCall),
    continuation: Continuation,
    usage: Option(types.Usage),
  )
  RunOutputLimited(
    partial_text: String,
    partial_calls: List(ToolCall),
    usage: Option(types.Usage),
  )
  RunRefusal(reason: String)
}

pub const tool_from_codec = types.tool_from_codec

pub type ToolDefinition =
  types.ToolDefinition

pub type ToolCall {
  ToolCall(id: CallId, name: ToolName, arguments_json: String)
}

pub type Usage =
  types.Usage

pub type StreamProgress =
  types.StreamProgress

pub type Outcome =
  types.Outcome

pub type RetryClassification =
  types.RetryClassification

pub type RetryHint =
  types.RetryHint

pub type RetryEvidence =
  types.RetryEvidence

pub type WireError =
  types.WireError

pub type TerminalOutcome =
  types.TerminalOutcome

pub type ReadResult =
  types.ReadResult

pub type ReadError =
  types.ReadError

pub type CloseOutcome =
  types.CloseOutcome

fn to_types_message(message: Message) -> types.Message {
  case message {
    SystemMessage(content) -> types.SystemMessage(content)
    UserMessage(content) -> types.UserMessage(content)
    UserContent(parts) -> types.UserContent(list.map(parts, to_types_content))
    AssistantMessage(content) -> types.AssistantMessage(content)
    AssistantContent(parts) ->
      types.AssistantContent(list.map(parts, to_types_content))
    AssistantToolCalls(calls) ->
      types.AssistantToolCalls(list.map(calls, to_types_tool_call))
    ToolResultMessage(call_id, content) ->
      types.ToolResultMessage(call_id, content)
  }
}

fn to_types_content(content: Content) -> types.Content {
  case content {
    TextContent(text) -> types.TextContent(text)
    ImageUrlContent(url) -> types.ImageUrlContent(url)
    InlineImageContent(mime_type, base64_data) ->
      types.InlineImageContent(mime_type, base64_data)
  }
}

fn to_types_prompt_cache(cache: PromptCache) -> types.PromptCache {
  case cache {
    OpenAiPromptCacheKey(key) -> types.OpenAiPromptCacheKey(key)
    GoogleCachedContent(name) -> types.GoogleCachedContent(name)
  }
}

fn to_types_tool_call(call: ToolCall) -> types.ToolCall {
  types.ToolCall(call.id, call.name, call.arguments_json, None, None)
}

fn from_types_tool_call(call: types.ToolCall) -> ToolCall {
  ToolCall(call.id, call.name, call.arguments_json)
}

fn to_types_tool_result(item: ToolResult) -> types.ToolResult {
  types.ToolResult(item.call_id, item.content)
}
