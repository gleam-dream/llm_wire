//// The provider adapter seam. `llm_wire/provider` builds these values;
//// built-in adapters build them directly.

import gleam/json
import gleam/option.{type Option}
import gleam/result
import json/blueprint/codec
import llm_wire/error.{type Error, type PrepareError}
import llm_wire/internal/limits.{type Limits}
import llm_wire/internal/sse
import llm_wire/message.{type Message, type Progress, type ToolCall, type Usage}

/// The admitted request an adapter encodes. Tools and output format are
/// passed separately, already projected.
pub type Request {
  Request(
    model: String,
    messages: List(Message),
    max_tokens: Option(Int),
    temperature: Option(Float),
    top_p: Option(Float),
    stop_sequences: List(String),
    prompt_cache: Option(PromptCache),
  )
}

/// A provider prompt cache reference.
pub type PromptCache {
  OpenAiPromptCacheKey(key: String)
  GoogleCachedContent(name: String)
}

pub type ProjectedTool {
  ProjectedTool(name: String, description: String, schema: json.Json)
}

pub type OutputFormat {
  OutputFormat(name: String, schema: json.Json)
}

pub type Encoded {
  Encoded(path: String, body: String)
}

pub type Event =
  sse.ServerSentEvent

/// How a reducer's response ended.
pub type Terminal {
  Text(text: String, usage: Option(Usage))
  ToolCalls(
    text: String,
    calls: List(ToolCall),
    response_id: Option(String),
    provider_data: Option(String),
    usage: Option(Usage),
  )
  OutputLimited(
    partial_text: String,
    partial_calls: List(ToolCall),
    usage: Option(Usage),
  )
  Refusal(reason: String, usage: Option(Usage))
  /// The provider reported a failure as the end of its response.
  Failed(error: Error, usage: Option(Usage))
}

pub type Reducer {
  Reducer(
    step: fn(Event) -> Result(#(Reducer, List(Progress)), Error),
    terminal: fn() -> Option(Terminal),
  )
}

pub opaque type Adapter {
  Adapter(
    provider: message.Provider,
    endpoint: String,
    headers: fn() -> List(#(String, String)),
    validate: fn() -> Result(Nil, PrepareError),
    encode: fn(Request, List(ProjectedTool), Option(OutputFormat)) ->
      Result(Encoded, PrepareError),
    project_tool_schema: fn(codec.Schema) -> Result(json.Json, String),
    project_output_schema: fn(codec.Schema) -> Result(json.Json, String),
    new_reducer: fn(Limits) -> Reducer,
  )
}

pub fn reducer(
  state: state,
  step: fn(state, Event) -> Result(#(state, List(Progress)), Error),
  terminal: fn(state) -> Option(Terminal),
) -> Reducer {
  Reducer(
    step: fn(event) {
      use #(next_state, progress) <- result.try(step(state, event))
      Ok(#(reducer(next_state, step, terminal), progress))
    },
    terminal: fn() { terminal(state) },
  )
}

pub fn new(
  provider provider: message.Provider,
  endpoint endpoint: String,
  headers headers: fn() -> List(#(String, String)),
  validate validate: fn() -> Result(Nil, PrepareError),
  encode encode: fn(Request, List(ProjectedTool), Option(OutputFormat)) ->
    Result(Encoded, PrepareError),
  project_tool_schema project_tool_schema: fn(codec.Schema) ->
    Result(json.Json, String),
  project_output_schema project_output_schema: fn(codec.Schema) ->
    Result(json.Json, String),
  new_reducer new_reducer: fn(Limits) -> Reducer,
) -> Adapter {
  Adapter(
    provider:,
    endpoint:,
    headers:,
    validate:,
    encode:,
    project_tool_schema:,
    project_output_schema:,
    new_reducer:,
  )
}

pub fn provider(adapter: Adapter) -> message.Provider {
  adapter.provider
}

pub fn endpoint(adapter: Adapter) -> String {
  adapter.endpoint
}

pub fn headers(adapter: Adapter) -> List(#(String, String)) {
  adapter.headers()
}

pub fn validate(adapter: Adapter) -> Result(Nil, PrepareError) {
  adapter.validate()
}

pub fn encode(
  adapter: Adapter,
  request: Request,
  tools: List(ProjectedTool),
  format: Option(OutputFormat),
) -> Result(Encoded, PrepareError) {
  adapter.encode(request, tools, format)
}

pub fn project_tool_schema(
  adapter: Adapter,
  schema: codec.Schema,
) -> Result(json.Json, String) {
  adapter.project_tool_schema(schema)
}

pub fn project_output_schema(
  adapter: Adapter,
  schema: codec.Schema,
) -> Result(json.Json, String) {
  adapter.project_output_schema(schema)
}

pub fn new_reducer(adapter: Adapter, limits: Limits) -> Reducer {
  adapter.new_reducer(limits)
}

pub fn with_endpoint(adapter: Adapter, endpoint: String) -> Adapter {
  Adapter(..adapter, endpoint:)
}

pub fn with_headers(
  adapter: Adapter,
  headers: fn() -> List(#(String, String)),
) -> Adapter {
  Adapter(..adapter, headers:)
}

pub fn with_tool_schema(
  adapter: Adapter,
  project: fn(codec.Schema) -> Result(json.Json, String),
) -> Adapter {
  Adapter(..adapter, project_tool_schema: project)
}

pub fn with_output_schema(
  adapter: Adapter,
  project: fn(codec.Schema) -> Result(json.Json, String),
) -> Adapter {
  Adapter(..adapter, project_output_schema: project)
}
