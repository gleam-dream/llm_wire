# llm_wire

A bounded LLM client for Gleam on Erlang/OTP. `llm_wire/config` holds provider
and execution settings; `llm_wire/session` prepares, runs, streams, and
continues interactions. `llm_wire/types` holds the request, message, tool call,
and tool result values shared across those paths. Preparation checks local
options and schemas before a network request.

## Make a call

Build provider options, then compose common execution settings. Preparation
returns `WireError`; execution returns `session.RunFailure(error, retry)` so a
caller can decide whether a request might have reached the provider.

```gleam
import llm_wire/config
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/types

let assert Ok(key) = types.api_key("sk-...")
let assert Ok(model) = types.model_id("gpt-...")
let options = openai.options(key) |> openai.with_project("my-project")
let limits = types.Limits(
  ..types.default_limits(),
  request_bytes_limit: 524_288,
)
let settings = config.openai(options) |> config.with_limits(limits)
let request =
  types.new_request(model, [types.UserMessage("Hello")])
  |> types.with_max_tokens(256)
let assert Ok(prepared) = session.prepare(settings, request)
let outcome = session.run(prepared)
```

Use `config.anthropic(anthropic.options(key))` or
`config.google(google.options(key))` for the other built-in adapters. Their
provider-specific options live in `llm_wire/provider/anthropic` and
`llm_wire/provider/google`. All three enter the same bounded HTTP/SSE runtime.
`RunText`, `RunToolCalls`, `RunOutputLimited`, and `RunRefusal` are distinct
successful outcomes. The library does not run tools or retry automatically.

`types.default_limits()` and `types.default_deadlines()` are bounded records.
Update fields by name and attach them with `config.with_limits` and
`config.with_deadlines`. `request_bytes_limit` bounds the outgoing JSON body;
`event_bytes_limit` independently bounds each incoming SSE event.
`provider_metadata_bytes_limit` bounds retained call IDs, tool names, provider
IDs/state, and response IDs. Opaque adapter replay closure state belongs to its
adapter. Preparation validates all limit and deadline fields before transport.

For a local HTTPS server signed by a private CA, compose an endpoint and CA
file:

```gleam
let settings =
  config.openai(openai.options(key))
  |> config.with_endpoint(endpoint)
  |> config.with_ca_cert_file("certs/local-ca.pem")
```

Preparation rejects an empty CA path, a plaintext endpoint with a CA file,
and remote hosts with a caller CA. Certificate and hostname verification apply
when streaming.

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
import json/blueprint/codec
import llm_wire/session
import llm_wire/types

let assert Ok(name) = types.tool_name("echo")
let assert Ok(echo_tool) = types.tool_from_codec(
  name, "Echo text", codec.field("text", codec.string()),
)
let request =
  types.new_request(model, [types.UserMessage("Echo hello")])
  |> types.with_tools([echo_tool])
let assert Ok(prepared) = session.prepare(settings, request)
let first = session.run(prepared)
case first {
  Ok(session.RunToolCalls(_text, calls, continuation, _usage)) -> {
    // The application executes each call and supplies the exact call IDs.
    let results = list.map(calls, fn(call) {
      types.ToolResult(call.id, "hello")
    })
    let assert Ok(next) = session.prepare_continue(continuation, results)
    session.run(next)
  }
  other -> other
}
```

`types.tool_from_contract(name, description, runtime_contract)` constructs a
schema-only tool from an admitted Blueprint `runtime.RuntimeContract` without a
dummy native type. The selected provider projects its schema during
preparation; unsupported variants fail there. Returned argument JSON receives
the same bounded schema validation as a codec-backed tool.

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
preparation. Structured-output JSON parsing uses the admitted text byte bound
while retaining Blueprint's bounded depth and number policy.

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
let settings = config.openai(openai.options(key)) |> config.with_pool(owned_pool)
// Prepare and run calls with `settings` while the application owns `owned_pool`.
let shutdown = pool.stop(owned_pool)
```

## Add an HTTP/SSE provider

An application can build `provider.Adapter(provider.Spec(...))` and pass it to
`config.from_provider(adapter)`. The spec supplies provider identity, endpoint,
auth or extra headers, request encoding, schema projection, and a reducer
factory. `provider.reducer(state, step, terminal, retry)` keeps application
state typed inside closures; `provider.replay(turn, encode)` keeps the complete
provider-authored assistant turn for tool continuation. The external consumer
fixture in [external_provider.gleam](test/external_provider.gleam) implements a
fourth provider using only public modules and runs against a real local
HTTP/SSE server.

The runtime supplies `Content-Type: application/json`,
`Accept: text/event-stream`, and `Accept-Encoding: identity` for every adapter.
Provider headers add authentication and other provider-specific fields;
attempts to override those fixed protocol headers fail preparation. The
runtime owns transport, deadlines, queue limits, retry evidence, tool catalog
validation, and terminal admission. Adapters must retain bounded opaque replay
state and enforce any wire-specific block limits when they emit aggregate-only
terminals; the runtime cannot inspect a closure's captured memory.

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

| Earlier call or type                                                   | Current public path                                                                                                       |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `llm_wire.prepare` / `run` / `stream` / `prepare_continue`             | `session.prepare` / `run` / `stream` / `prepare_continue`, with `config.Config` retaining settings                        |
| Root `Message`, reduced `ToolCall`, `ToolResult`, `RunResult`          | `types.Message`, full `types.ToolCall`, `types.ToolResult`, `session.RunResult`                                           |
| `config.openai(key)` / `anthropic(key)` / `google(key)`                | `config.openai(openai.options(key))` and analogous provider option builders                                               |
| Fallible `config.with_openai_*` / `with_anthropic_*` / `with_google_*` | Compose typed options in the matching `llm_wire/provider/*` module before common configuration                            |
| `types.new_limits` / `new_deadlines`                                   | Update `types.default_limits()` / `default_deadlines()` records; `session.prepare` validates the whole config             |
| Outgoing request checked against `event_bytes_limit`                   | Set `request_bytes_limit` independently; event and request defaults remain 1 MiB                                          |
| Buffered execution or stream opening returns `WireError` directly      | Match `session.RunFailure(error, retry)`; preparation still returns `WireError`                                           |
| Tool-call outcome omitted assistant text                               | `RunToolCalls(text, calls, continuation, usage)` preserves text and provider-authored replay                              |
| Tool arguments parsed with Blueprint's 10 MiB default                  | Parser byte bounds now follow `argument_bytes_per_call_limit`; depth and number policy stay bounded                       |
| Structured output parsed with Blueprint's 10 MiB default               | Parser byte bound follows the smaller admitted per-block and total text limits                                            |
| `types.with_provider_continuation`                                     | `session.prepare_continue` with the opaque continuation returned by `session.run`                                         |
| Direct internal provider reducer and request hooks                     | Use `provider.Adapter`/`provider.Spec`/`provider.reducer`, then `config.from_provider`; internal transport is unsupported |
