//// Starts a call owner over a built-in reducer and a test transport, for
//// tests of the owner's bounds, timers and delivery.

import gleam/option.{type Option, None}
import llm_wire/internal/adapter
import llm_wire/internal/builtin
import llm_wire/internal/config
import llm_wire/internal/limits.{type Limits}
import llm_wire/internal/observe
import llm_wire/internal/owner
import llm_wire/internal/tool_def
import llm_wire/tool

pub fn context() -> observe.Context {
  observe.Context(call: "owner-test", correlation: None, provider: "test")
}

pub fn start(
  provider_adapter: adapter.Adapter,
  limits: Limits,
  timeouts: config.Timeouts,
  transport: owner.TransportPort,
  tools: List(tool_def.Tool),
) -> Result(owner.Stream, Nil) {
  owner.start(
    owner.Setup(
      context: context(),
      reducer: adapter.new_reducer(provider_adapter, limits),
      limits:,
      timeouts:,
      tools:,
      checks: tool.RejectInvalidToolCalls,
    ),
    timeouts.whole_call,
    fn(_) { transport },
  )
}

pub fn start_openai_stream(
  limits: Limits,
  timeouts: config.Timeouts,
  transport: owner.TransportPort,
) -> Result(owner.Stream, Nil) {
  start_openai_stream_with_tools(limits, timeouts, transport, [])
}

pub fn start_openai_stream_with_tools(
  limits: Limits,
  timeouts: config.Timeouts,
  transport: owner.TransportPort,
  tools: List(tool_def.Tool),
) -> Result(owner.Stream, Nil) {
  start(
    builtin.openai_adapter(fn() { "owner-test" }, None, None),
    limits,
    timeouts,
    transport,
    tools,
  )
}

pub fn start_anthropic_stream_with_tools(
  limits: Limits,
  timeouts: config.Timeouts,
  transport: owner.TransportPort,
  tools: List(tool_def.Tool),
) -> Result(owner.Stream, Nil) {
  start(
    builtin.anthropic_adapter(fn() { "owner-test" }, None),
    limits,
    timeouts,
    transport,
    tools,
  )
}

/// Timeouts in milliseconds; `None` is unbounded.
pub fn timeouts(
  whole_call: Option(Int),
  first_token: Option(Int),
  idle_gap: Option(Int),
) -> config.Timeouts {
  config.Timeouts(whole_call:, first_token:, idle_gap:)
}
