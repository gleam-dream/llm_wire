import gleam/json
import gleam/option.{type Option}
import gleam/result
import json/blueprint/codec
import llm_wire/internal/schema as schema_bridge
import llm_wire/types

/// One admitted HTTP/SSE provider. The runtime, rather than the adapter,
/// owns transport, deadlines, byte limits, and stream delivery.
pub opaque type Adapter {
  Adapter(spec: Spec)
}

/// Provider-owned wire policy. Every callback is pure; construction allocates
/// no transport resources. `encode` receives only locally admitted requests.
pub type Spec {
  Spec(
    identity: types.Provider,
    endpoint: types.Endpoint,
    headers: List(#(String, String)),
    encode: fn(types.Request, List(ProjectedTool), Option(OutputFormat)) ->
      Result(EncodedRequest, types.WireError),
    project_tool_schema: fn(codec.Schema) -> Result(json.Json, types.WireError),
    project_output_schema: fn(codec.Schema) ->
      Result(json.Json, types.WireError),
    new_reducer: fn(types.Limits, List(types.ToolDefinition)) ->
      Result(Reducer, types.WireError),
  )
}

pub type EncodedRequest {
  EncodedRequest(path: String, body: String)
}

pub type OutputFormat {
  OutputFormat(name: String, schema: json.Json)
}

/// Tool schemas after this provider's projection has admitted them.
pub type ProjectedTool {
  ProjectedTool(name: types.ToolName, description: String, schema: json.Json)
}

pub type Event {
  Event(
    event: Option(String),
    data: String,
    id: Option(String),
    retry: Option(Int),
  )
}

pub type Terminal {
  Text(text: String, usage: Option(types.Usage))
  ToolCalls(
    text: String,
    calls: List(types.ToolCall),
    response_id: Option(String),
    provider_data: Option(String),
    usage: Option(types.Usage),
  )
  OutputLimited(
    partial_text: String,
    partial_calls: List(types.ToolCall),
    usage: Option(types.Usage),
  )
  Refusal(reason: String, usage: Option(types.Usage))
  Failure(error: types.WireError, retry: types.RetryEvidence)
  Cancellation(retry: types.RetryEvidence)
}

/// The generic reducer state stays inside these closures. Neither Config nor
/// Stream acquires a provider-specific type parameter.
pub opaque type Reducer {
  Reducer(
    step: fn(Event) ->
      Result(#(Reducer, List(types.StreamProgress)), types.WireError),
    terminal: fn() -> Option(Terminal),
    retry: fn(types.RetryClassification) -> types.RetryEvidence,
  )
}

pub fn reducer(
  state: state,
  step: fn(state, Event) ->
    Result(#(state, List(types.StreamProgress)), types.WireError),
  terminal: fn(state) -> Option(Terminal),
  retry: fn(state, types.RetryClassification) -> types.RetryEvidence,
) -> Reducer {
  Reducer(
    step: fn(event) {
      use #(next_state, progress) <- result.try(step(state, event))
      Ok(#(reducer(next_state, step, terminal, retry), progress))
    },
    terminal: fn() { terminal(state) },
    retry: fn(fallback) { retry(state, fallback) },
  )
}

pub fn adapter(spec: Spec) -> Adapter {
  Adapter(spec)
}

/// Projects Blueprint's canonical finite schema subset to provider JSON.
/// Adapters may apply stricter provider-specific rules after this bridge.
pub fn blueprint_schema(
  schema: codec.Schema,
) -> Result(json.Json, types.WireError) {
  schema_bridge.codec_schema_to_json(schema)
}

pub fn identity(adapter: Adapter) -> types.Provider {
  adapter.spec.identity
}

pub fn endpoint(adapter: Adapter) -> types.Endpoint {
  adapter.spec.endpoint
}

pub fn headers(adapter: Adapter) -> List(#(String, String)) {
  adapter.spec.headers
}

pub fn with_endpoint(adapter: Adapter, endpoint: types.Endpoint) -> Adapter {
  Adapter(spec: Spec(..adapter.spec, endpoint: endpoint))
}

pub fn encode(
  adapter: Adapter,
  request: types.Request,
  tools: List(ProjectedTool),
  format: Option(OutputFormat),
) -> Result(EncodedRequest, types.WireError) {
  adapter.spec.encode(request, tools, format)
}

pub fn project_tool_schema(
  adapter: Adapter,
  schema: codec.Schema,
) -> Result(json.Json, types.WireError) {
  adapter.spec.project_tool_schema(schema)
}

pub fn project_output_schema(
  adapter: Adapter,
  schema: codec.Schema,
) -> Result(json.Json, types.WireError) {
  adapter.spec.project_output_schema(schema)
}

pub fn new_reducer(
  adapter: Adapter,
  limits: types.Limits,
  tools: List(types.ToolDefinition),
) -> Result(Reducer, types.WireError) {
  adapter.spec.new_reducer(limits, tools)
}

pub fn step(
  reducer: Reducer,
  event: Event,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  reducer.step(event)
}

pub fn terminal(reducer: Reducer) -> Option(Terminal) {
  reducer.terminal()
}

pub fn retry_evidence(
  reducer: Reducer,
  fallback: types.RetryClassification,
) -> types.RetryEvidence {
  reducer.retry(fallback)
}
