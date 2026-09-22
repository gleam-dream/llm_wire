# llm_wire

A bounded LLM client for Gleam on Erlang/OTP. `llm_wire/config` holds provider
and execution settings; `llm_wire/session` prepares, runs, streams, and
continues interactions. `llm_wire/types` holds the request, message, tool call,
and tool result values shared across those paths. Preparation checks local
options and schemas before a network request.

## Make a call

```gleam
import gleam/result
import llm_wire/config
import llm_wire/session
import llm_wire/types

pub fn ask(
  key: types.ApiKey,
  model: types.ModelId,
  question: String,
) -> Result(session.RunResult, types.WireError) {
  let request =
    types.new_request(model, [types.UserMessage(question)])
    |> types.with_max_tokens(256)
  use prepared <- result.try(session.prepare(config.openai(key), request))
  session.run(prepared)
}
```

Construct credentials and model IDs with `types.api_key` and `types.model_id`.
For Anthropic or Google, use `config.anthropic(key)` or `config.google(key)`.
`session.run` returns `RunText`, `RunToolCalls`, `RunOutputLimited`, or
`RunRefusal`; match each outcome as your application requires. It does not
automatically execute tools or retry a request. Provider-specific config
modifiers return `Result` and reject a mismatched provider.

Settings compose value first. The built-in defaults are bounded; update only
the settings your application needs. `session.prepare` validates the resulting
records before any network request:

```gleam
let limits =
  types.Limits(..types.default_limits(), event_bytes_limit: 524_288)
let deadlines =
  types.Deadlines(..types.default_deadlines(), overall_timeout_ms: 30_000)
let settings =
  config.openai(key)
  |> config.with_limits(limits)
  |> config.with_deadlines(deadlines)
```

These timeouts are durations applied when an interaction runs. A continuation
keeps the originating settings and starts with fresh execution timeouts.

Provider-specific modifiers return `Result`. For example, an OpenAI project
setting can be composed before preparation:

```gleam
use settings <- result.try(
  config.with_openai_project(config.openai(key), "my-project"),
)
use prepared <- result.try(session.prepare(settings, request))
session.run(prepared)
```

For a local HTTPS server signed by a private CA, set an endpoint and CA file:

```gleam
let settings =
  config.openai(key)
  |> config.with_endpoint(endpoint)
  |> config.with_ca_cert_file("certs/local-ca.pem")
```

Preparation rejects an empty CA path, plaintext endpoint, or remote host with
a caller CA. Certificate and hostname verification still apply when streaming.

## Continue a tool call

The tool catalog is declared with a Blueprint codec. A `RunToolCalls` outcome
contains full `types.ToolCall` values and an opaque continuation. Return
`types.ToolResult` values with the exact call IDs. The continuation validates
the result set and restores the original call order, request, provider replay
state, and settings. For manually authored history, `types.tool_call(id, name,
arguments_json)` starts with absent provider metadata; a full `types.ToolCall`
record preserves provider IDs and state when importing a provider-originated
call.

```gleam
import gleam/list
import gleam/result
import json/blueprint/codec
import llm_wire/config
import llm_wire/session
import llm_wire/types

fn echo_result(call: types.ToolCall) -> Result(types.ToolResult, types.WireError) {
  case types.tool_name_to_string(call.name) {
    "echo" ->
      case codec.decode_json(
        codec.field("text", codec.string()),
        call.arguments_json,
      ) {
        Ok(text) -> Ok(types.ToolResult(call.id, text))
        Error(_) -> Error(types.ProtocolError("Invalid echo arguments"))
      }
    _ -> Error(types.ProtocolError("Unexpected tool call"))
  }
}

pub fn echo_once(
  key: types.ApiKey,
  model: types.ModelId,
) -> Result(session.RunResult, types.WireError) {
  let assert Ok(name) = types.tool_name("echo")
  use echo_tool <- result.try(types.tool_from_codec(
    name, "Echo text", codec.field("text", codec.string()),
  ))
  let request =
    types.new_request(model, [types.UserMessage("Echo hello")])
    |> types.with_tools([echo_tool])
  use prepared <- result.try(session.prepare(config.openai(key), request))
  use first <- result.try(session.run(prepared))
  case first {
    session.RunToolCalls(calls, continuation, _) -> {
      use results <- result.try(list.try_map(calls, echo_result))
      use next <- result.try(session.prepare_continue(continuation, results))
      session.run(next)
    }
    other -> Ok(other)
  }
}
```

Handle another `RunToolCalls` result with another continuation round if your
application permits it. Set an application limit on tool rounds.

## Structured output and streaming

`session.prepare_structured(settings, request, name, codec)` keeps the output
codec through tool continuation. Use `session.run_structured` for a decoded
`StructuredValue`, or match `StructuredNeedsTools`,
`StructuredOutputLimited`, and `StructuredRefusal`. Continue tools with
`session.prepare_structured_continue(continuation, results)`.

```gleam
let output_codec = codec.field("answer", codec.int())
let assert Ok(prepared) =
  session.prepare_structured(settings, request, "answer_shape", output_codec)
let result = session.run_structured(prepared)
```

The structured schema must be a closed object with required properties.
`codec.field` and an equivalent one-property `codec.object` are both admitted.
Optional fields remain optional and fail strict admission. Google additionally
rejects nullable schemas. Unsupported provider schema forms fail during
preparation.

For progress events, open a stream and read until a terminal outcome:

```gleam
fn read_stream(stream: session.Stream) -> Result(session.Terminal, session.ReadError) {
  case session.next(stream) {
    Ok(session.NextProgress(_progress)) -> {
      // Handle progress here.
      read_stream(stream)
    }
    Ok(session.StreamTerminal(terminal)) -> Ok(terminal)
    Error(session.StreamReadError(types.ReadTimeout)) -> read_stream(stream)
    Error(error) -> Error(error)
  }
}

let assert Ok(stream) = session.stream(prepared)
let terminal = read_stream(stream)
```

`session.next` takes its read timeout from the prepared config. A stream
retains its prepared call, so a tool terminal carries the correct continuation.
Use `session.close(stream)` when abandoning a stream. Structured streaming uses
`session.stream_structured`, `session.next_structured`, and
`session.close_structured` with the same ownership pattern.

## Own a connection pool

`config` is pure and never starts a pool. Start one in your application's
supervision or startup path, attach it, and stop it during shutdown:

```gleam
import llm_wire/pool

let assert Ok(owned_pool) = pool.start(pool.default_pool_config())
let settings = config.openai(key) |> config.with_pool(owned_pool)
// Prepare and run calls with `settings` while the application owns `owned_pool`.
let shutdown = pool.stop(owned_pool)
```

## Observe and integrate

`llm_wire/telemetry.observation_event()` is a typed Sinal event. Subscribe
with `sinal.observe` and detach when finished:

```gleam
import gleam/erlang/process
import llm_wire/telemetry
import sinal

let received = process.new_subject()
let assert Ok(handler_id) = sinal.handler_id("my_llm_observer")
let assert Ok(attachment) =
  sinal.observe(handler_id, telemetry.observation_event(), fn(_, metadata) {
    process.send(received, metadata)
  })
// At application shutdown:
let _ = sinal.detach(attachment)
```

The metadata is `telemetry.Metadata(stage, provider, outcome)`.
Package observations emit only these fixed, low-cardinality fields under the
native `[:llm_wire, :observation]` event. They carry no prompt or response
content.

Applications that use Relay can adapt their own `relay/tool.Definition` to an
LLM tool declaration through its input codec. This adapter belongs in the
application and requires Relay only there:

```gleam
import gleam/option
import gleam/result
import llm_wire/types
import relay/tool

fn llm_tool_from_relay(
  definition: tool.Definition(input, output),
) -> Result(types.ToolDefinition, types.WireError) {
  let name = tool.definition_name(definition) |> tool.tool_name_to_string
  let metadata = tool.definition_metadata(definition)
  let description = option.unwrap(metadata.description, name)
  use llm_name <- result.try(types.tool_name(name))
  types.tool_from_codec(
    llm_name,
    description,
    tool.definition_input_codec(definition),
  )
}
```

The application still owns dispatch, tool execution, output encoding, and
`types.ToolResult` construction.

## Pre-release API migration

The earlier root and wire APIs were never released. They have no compatibility
shims in this cleanup.

| Earlier call or type                                                          | Current public path                                                                                           |
| ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `llm_wire.prepare` / `run` / `stream` / `prepare_continue`                    | `session.prepare` / `run` / `stream` / `prepare_continue`, with `config.Config` retaining settings            |
| Root `Message`, reduced `ToolCall`, `ToolResult`, `RunResult`                 | `types.Message`, full `types.ToolCall`, `types.ToolResult`, `session.RunResult`                               |
| `types.openai_config` / `anthropic_config` / `google_config`                  | `config.openai` / `anthropic` / `google`, then value-first modifiers                                          |
| `types.new_limits` / `new_deadlines`                                          | Update `types.default_limits()` / `default_deadlines()` records; `session.prepare` validates the whole config |
| `types.with_provider_continuation`                                            | `session.prepare_continue` with the opaque continuation returned by `session.run`                             |
| Direct `api`, `runtime`, provider reducer, owner, SSE, schema, or TCP modules | `session` and `types`; protocol plumbing lives under `llm_wire/internal`                                      |
