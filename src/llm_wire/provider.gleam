//// Adds a provider that the built-in OpenAI, Anthropic and Google adapters
//// do not cover.
////
//// An adapter supplies only what differs between providers: how a request
//// is encoded and how the event stream is reduced. The runtime keeps the
//// rest for every adapter: transport through the caller's HTTP Gun client,
//// the three timers, byte limits, tool-call admission, telemetry and
//// cleanup.
////
//// ```gleam
//// import llm_wire
//// import llm_wire/provider
////
//// let config =
////   provider.new(message.Custom("acme"), "https://llm.acme.test/v1", encode, fn() {
////     provider.reducer(initial_state, step, terminal)
////   })
////   |> provider.with_headers(fn() { [#("authorization", "Bearer " <> key())] })
////   |> provider.config
//// ```
////
//// `encode` receives the admitted `Request` (read its fields by label:
//// `model`, `messages`, `max_tokens`, `temperature`, `top_p`,
//// `stop_sequences`, `prompt_cache`), the tools after schema projection
//// (`name`, `description`, `schema`) and the structured-output format
//// (`name`, `schema`), and returns `encoded(path, body)`, where `path` is
//// appended to the endpoint. A reducer turns each server-sent `Event`
//// (`event`, `data`, `id`, `retry`) into `message.Progress` values, and
//// ends with a `Terminal` built by `text`, `tool_calls`, `output_limited`,
//// `refused` or `failed`.
////
//// Credentials belong in the `with_headers` closure, so they never print
//// with the adapter or a configuration. `step` and `terminal` drive a
//// reducer directly, for testing it without a server.

import gleam/json
import gleam/option.{type Option, None}
import json/blueprint/codec
import llm_wire
import llm_wire/error.{type Error, type PrepareError}
import llm_wire/internal/adapter
import llm_wire/internal/config
import llm_wire/internal/schema
import llm_wire/internal/sse
import llm_wire/message.{type Progress, type Provider, type ToolCall, type Usage}

/// An HTTP/SSE provider adapter.
pub type Adapter =
  adapter.Adapter

/// A reducer over the provider's event stream; its state stays inside it.
pub type Reducer =
  adapter.Reducer

/// The admitted request an adapter encodes.
pub type Request =
  adapter.Request

/// A provider prompt cache reference, read from `Request.prompt_cache`.
pub type PromptCache =
  adapter.PromptCache

/// A tool after this adapter's schema projection.
pub type ProjectedTool =
  adapter.ProjectedTool

/// The structured-output format after projection.
pub type OutputFormat =
  adapter.OutputFormat

/// An encoded request: a path below the endpoint and a JSON body.
pub type Encoded =
  adapter.Encoded

/// One server-sent event.
pub type Event =
  adapter.Event

/// How a reducer's response ended.
pub type Terminal =
  adapter.Terminal

/// An adapter for `provider` at `endpoint`. Tool and output schemas are
/// projected with `blueprint_schema` until `with_tool_schema` or
/// `with_output_schema` replace it; no headers are sent until
/// `with_headers`.
pub fn new(
  provider: Provider,
  endpoint: String,
  encode: fn(Request, List(ProjectedTool), Option(OutputFormat)) ->
    Result(Encoded, PrepareError),
  reducer: fn() -> Reducer,
) -> Adapter {
  adapter.new(
    provider:,
    endpoint:,
    headers: fn() { [] },
    validate: fn() { Ok(Nil) },
    encode:,
    project_tool_schema: blueprint_schema,
    project_output_schema: blueprint_schema,
    new_reducer: fn(_) { reducer() },
  )
}

/// Send these headers with every request. The closure runs when a request
/// is prepared, so a credential read inside it never prints.
pub fn with_headers(
  provider_adapter: Adapter,
  headers: fn() -> List(#(String, String)),
) -> Adapter {
  adapter.with_headers(provider_adapter, headers)
}

/// Project tool input schemas with `project`; an `Error` reason makes
/// `prepare` fail with `error.UnsupportedSchema`.
pub fn with_tool_schema(
  provider_adapter: Adapter,
  project: fn(codec.Schema) -> Result(json.Json, String),
) -> Adapter {
  adapter.with_tool_schema(provider_adapter, project)
}

/// Project structured-output schemas with `project`.
pub fn with_output_schema(
  provider_adapter: Adapter,
  project: fn(codec.Schema) -> Result(json.Json, String),
) -> Adapter {
  adapter.with_output_schema(provider_adapter, project)
}

/// The configuration of a call through this adapter, with the default
/// limits, timeouts and tool-call checks.
pub fn config(provider_adapter: Adapter) -> llm_wire.Config {
  config.new(provider_adapter)
}

/// Blueprint's canonical JSON Schema for `schema`. Adapters may apply
/// stricter provider rules after it.
pub fn blueprint_schema(schema: codec.Schema) -> Result(json.Json, String) {
  schema.codec_schema_to_json(schema)
}

/// A reducer from an initial state, a step function and a terminal check.
pub fn reducer(
  state: state,
  step: fn(state, Event) -> Result(#(state, List(Progress)), Error),
  terminal: fn(state) -> Option(Terminal),
) -> Reducer {
  adapter.reducer(state, step, terminal)
}

pub fn encoded(path: String, body: String) -> Encoded {
  adapter.Encoded(path:, body:)
}

/// A server-sent event with this event name and data, for tests.
pub fn event(name: Option(String), data: String) -> Event {
  sse.ServerSentEvent(event: name, data:, id: None, retry: None)
}

/// Step a reducer with one event.
pub fn step(
  reducer: Reducer,
  event: Event,
) -> Result(#(Reducer, List(Progress)), Error) {
  reducer.step(event)
}

/// The reducer's terminal, once its response ended.
pub fn terminal(reducer: Reducer) -> Option(Terminal) {
  reducer.terminal()
}

/// A final text answer.
pub fn text(text: String, usage: Option(Usage)) -> Terminal {
  adapter.Text(text, usage)
}

/// Tool calls awaiting results. `provider_data` is opaque replay data the
/// adapter's `encode` receives back in the assistant turn.
pub fn tool_calls(
  text: String,
  calls: List(ToolCall),
  response_id: Option(String),
  provider_data: Option(String),
  usage: Option(Usage),
) -> Terminal {
  adapter.ToolCalls(text, calls, response_id, provider_data, usage)
}

/// Output cut off by the provider's token limit.
pub fn output_limited(
  partial_text: String,
  partial_calls: List(ToolCall),
  usage: Option(Usage),
) -> Terminal {
  adapter.OutputLimited(partial_text, partial_calls, usage)
}

pub fn refused(reason: String, usage: Option(Usage)) -> Terminal {
  adapter.Refusal(reason, usage)
}

/// The provider ended its response with an error.
pub fn failed(error: Error, usage: Option(Usage)) -> Terminal {
  adapter.Failed(error, usage)
}
