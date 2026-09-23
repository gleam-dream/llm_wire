import gleam/option.{None}
import gleam/result
import llm_wire/internal/api
import llm_wire/internal/owner
import llm_wire/provider
import llm_wire/types

pub fn start_openai_stream(
  limits: types.Limits,
  deadlines: types.Deadlines,
  transport: owner.TransportPort,
) -> Result(owner.Stream, types.WireError) {
  start_openai_stream_with_tools(limits, deadlines, transport, [])
}

pub fn start_openai_stream_with_tools(
  limits: types.Limits,
  deadlines: types.Deadlines,
  transport: owner.TransportPort,
  tools: List(types.ToolDefinition),
) -> Result(owner.Stream, types.WireError) {
  let assert Ok(key) = types.api_key("owner-test")
  let assert Ok(endpoint) = types.endpoint("https://example.test")
  let adapter = api.openai_adapter(key, endpoint, None, None)
  use reducer <- result.try(provider.new_reducer(adapter, limits, tools))
  owner.start_provider_stream(
    types.OpenAI,
    reducer,
    limits,
    deadlines,
    transport,
    tools,
  )
}

pub fn start_anthropic_stream_with_tools(
  limits: types.Limits,
  deadlines: types.Deadlines,
  transport: owner.TransportPort,
  tools: List(types.ToolDefinition),
) -> Result(owner.Stream, types.WireError) {
  let assert Ok(key) = types.api_key("owner-test")
  let assert Ok(endpoint) = types.endpoint("https://example.test")
  let adapter = api.anthropic_adapter(key, endpoint, None)
  use reducer <- result.try(provider.new_reducer(adapter, limits, tools))
  owner.start_provider_stream(
    types.Anthropic,
    reducer,
    limits,
    deadlines,
    transport,
    tools,
  )
}
