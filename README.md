# llm_wire

A bounded LLM client for Gleam on Erlang/OTP. `llm_wire/config` holds provider
and execution settings; `llm_wire/session` prepares, runs, streams, and
continues interactions. `llm_wire/types` holds the request, message, tool call,
and tool result values shared across those paths. Preparation checks local
options and schemas before a network request.

The package targets Gleam 1.18 or newer on Erlang/OTP. The checked-in Nix
development shell uses OTP 28; other OTP versions have not been verified in
this release candidate. The JavaScript target is unsupported. The current
dependency manifest uses local Blueprint and Sinal path dependencies, so the
package is not yet ready for an independent registry install.

The initial release scope and remaining release decisions are recorded in
[CHANGELOG.md](CHANGELOG.md). The exercised behavior is tracked in
[DESIGN-COVERAGE.md](DESIGN-COVERAGE.md).

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
IDs/state, response IDs, and each response's opaque provider data. Preparation validates all limit and deadline fields before transport.

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

## Build a conversation with tool results

`RunToolCalls(turn, usage)` returns an immutable `types.AssistantTurn` with text,
calls, response ID, provider data, and reported issues. It holds no conversation,
configuration, or callback. Your application owns the message list and tool loop.
Keep the returned turn intact as an `AssistantTurnMessage` so signed provider
parts remain attached to the correct response.

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
case session.run(prepared) {
  Ok(session.RunToolCalls(turn, _usage)) -> {
    // Your application executes the calls and creates their result messages.
    let results = list.map(turn.calls, fn(call) {
      types.ToolResultMessage(call.id, "hello")
    })
    let next_request = types.Request(
      ..request,
      messages: list.append(request.messages, [
        types.AssistantTurnMessage(turn), ..results
      ]),
    )
    let assert Ok(next) = session.prepare(settings, next_request)
    session.run(next)
  }
  other -> other
}
```

Each assistant tool batch must be followed by exactly one result per call.
Preparation rejects missing, duplicate, unknown, and orphan results before I/O
and orders results within each batch. Call IDs may recur in different turns.
Historical calls need not name a tool present in the current catalog.

`types.tool_name` admits `^[a-zA-Z0-9_-]{1,64}$`, the name grammar shared by
OpenAI, Anthropic, and Google. It does not trim, and it returns a typed
`types.ToolNameError` (`EmptyToolName`, `InvalidToolNameCharacter`, or
`ToolNameTooLong`) instead of a provider error.

`types.tool_from_contract(name, description, runtime_contract)` constructs a
schema-only tool from an admitted Blueprint `runtime.RuntimeContract` without a
dummy native type. The selected provider projects its schema during
preparation; unsupported variants fail there. Returned argument JSON receives
the same bounded schema validation as a codec-backed tool.

Handle another `RunToolCalls` result by extending the conversation again if your
application permits it. Set an application limit on tool rounds.

By default a response whose call names an undeclared tool, or whose arguments
are not valid JSON or fail the tool schema, fails with `ProtocolError`. An agent
that answers such calls itself selects reporting instead:

```gleam
let settings =
  config.openai(openai.options(key))
  |> config.with_tool_call_checks(types.ReportInvalidToolCalls)
// After session.run returns RunToolCalls(turn, _):
let issues = turn.issues
// [types.UnknownTool(call_id), types.InvalidArguments(call_id, reason), ...]
```

Every call stays in `turn.calls`. Supply an error result for each reported call
when building the next request. OpenAI receives argument text verbatim;
Anthropic and Google require an object, so unsigned argument text that is not a
JSON object is sent as `{"unparsed_arguments": text}`. Signed Google parts remain
unchanged. Argument bounds, duplicate call IDs, and invalid tool names still
fail the response. Streamed and structured tool responses expose the same turn.

## Structured output and streaming

`session.prepare_structured(settings, request, name, codec)` selects the output
codec for one request. Use `session.run_structured` for a decoded
`StructuredValue`, or match `StructuredNeedsTools(turn, usage)`,
`StructuredOutputLimited`, and `StructuredRefusal`. After tools run, build a new
request and call `prepare_structured` with the desired codec again.

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
retains its prepared call for transport settings and response interpretation.
Use `session.close(stream)` when abandoning a stream. Structured streaming uses
`session.stream_structured`, `session.next_structured`, and
`session.close_structured` with the same ownership pattern.

## Conversation ownership

Fabric or another consumer owns agent progress, storage, pause/resume, and
protection against duplicate tool effects. LLM Wire has no continuation handles,
checkpoint export/import, or durable execution format. Its prepared values belong
to one request. Supply the complete conversation explicitly on every request.

An `AssistantTurn` is response data, not an execution record. Provider data is
interpreted by the configured adapter and must remain with its original text and
calls. Cross-provider turns and contradictory Google raw parts fail preparation.
See the [boundary contract](docs/caller-owned-conversation.md) and
[Fabric migration notes](docs/fabric-migration.md).

## Assess another attempt

`retry.assess(provider, error)` returns `MayHelp`, `WillNotHelpUnchanged`, or
`Unknown`. It interprets known status and provider error codes without scheduling
an attempt. `RetryEvidence` continues to describe reachability and progress.
Applications combine both with tool effects, Retry-After hints, deadlines, and
budgets when deciding whether to retry. A `MayHelp` result does not establish
that repeating an operation is safe.

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

An application can build `provider.adapter(provider.Spec(...))` and pass it to
`config.from_provider(adapter)`. The spec supplies provider identity, endpoint,
auth or extra headers, request encoding, schema projection, and a reducer
factory. `provider.reducer(state, step, terminal, retry)` keeps application
reducer state typed inside closures for one response. A `provider.ToolCalls`
terminal supplies optional data as a string; the encoder reads it from each
`AssistantTurnMessage` in subsequent requests. The adapter owns the data format
and its semantic validation. The external consumer
fixture in [external_provider.gleam](test/external_provider.gleam) implements a
fourth provider using only public modules and runs against a real local
HTTP/SSE server.

The runtime supplies `Content-Type: application/json`,
`Accept: text/event-stream`, and `Accept-Encoding: identity` for every adapter.
Provider headers add authentication and other provider-specific fields;
attempts to override those fixed protocol headers fail preparation. The
runtime owns transport, deadlines, queue limits, retry evidence, tool catalog
validation, and terminal admission. The runtime bounds returned provider data. Adapters must also bound reducer
state and enforce wire-specific block limits while accumulating a response.

## Test without a network

`llm_wire/testing` scripts provider replies for application tests. A script
is a process that serves queued replies in order and records each admitted
request. The replies enter the same stream owner, SSE framer, reducer, limits,
deadlines, and terminal admission as a real response. No socket opens.

```gleam
import llm_wire/session
import llm_wire/testing
import llm_wire/types

let script =
  testing.start([
    testing.tool_calls("", [
      testing.ScriptedCall("call_1", "lookup", "{\"query\":\"gleam\"}"),
    ]),
    testing.text("Found it.") |> testing.with_usage(types.Usage(12, 3, 15)),
  ])
let assert Ok(prepared) = session.prepare(testing.config(script), request)
let assert Ok(session.RunToolCalls(turn, _)) = session.run(prepared)
let assert [call] = turn.calls
let next_request = types.Request(..request, messages: list.append(request.messages, [
  types.AssistantTurnMessage(turn), types.ToolResultMessage(call.id, "gleam.run")
]))
let assert Ok(next) = session.prepare(testing.config(script), next_request)
let assert Ok(session.RunText("Found it.", _)) = session.run(next)
let assert [_, second] = testing.requests(script)
// second.request.messages ends with the assistant calls and the tool result.
```

`testing.config(script)` selects a provider-neutral scripted provider. Its
replies come from `text`, `tool_calls`, `refusal`, and `output_limited`.
`testing.with_script(settings, script)` routes any configuration, including a
built-in provider, through the script; those replies carry that provider's raw
SSE bytes in `testing.Events(chunks)`. `testing.Interrupted(chunks)` ends with
a transport failure, and `testing.Status(code, body)` fails before a stream
opens. A request with no reply left fails with `ConfigurationError` and is
still recorded.

## Play a cassette from disk

Choose the transport once when configuring a flow. The flow keeps its ordinary
`session.prepare`, `run`, and `stream` calls in both environments:

```gleam
import llm_wire/cassette

// Production:
let production_settings = config.openai(openai.options(key))

// Local playback:
let assert Ok(recording) = cassette.load("fixtures/lookup.json", 8_388_608)
let script = cassette.start(recording)
let local_settings = testing.with_script(production_settings, script)
// Pass either settings value to the same application flow.
```

Version 1 cassettes store ordered exchanges. Each expected request matches the
POST method, configured endpoint, effective path, and exact body. Configured
headers and their credentials are excluded; request and response bodies are
retained verbatim. Repeated identical requests can have different
responses. A mismatch leaves the expected exchange unconsumed; mismatches and
exhaustion return errors with no network fallback. `testing.remaining(script)`
lets a test assert that it used every exchange.

`cassette.parse` and `to_json` support application-controlled fixture storage;
`load` bounds file reads before allocating the complete file. Malformed,
unsupported, oversized, and excessively nested data return typed cassette errors.
Replies preserve SSE chunk boundaries, HTTP status failures and interruptions.
This release adds playback; automatic live recording is not implemented.

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
  use llm_name <- result.try(
    types.tool_name(name)
    |> result.replace_error(types.PreparationError("Invalid tool name: " <> name)),
  )
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

| Earlier call or type                                                       | Current public path                                                                                                       |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `llm_wire.prepare` / `run` / `stream`                                      | `session.prepare` / `run` / `stream`, with `config.Config` retaining settings                                             |
| Root `Message`, reduced `ToolCall`, `ToolResult`, `RunResult`              | `types.Message`, full `types.ToolCall`, `types.ToolResult`, `session.RunResult`                                           |
| `config.openai(key)` / `anthropic(key)` / `google(key)`                    | `config.openai(openai.options(key))` and analogous provider option builders                                               |
| Fallible `config.with_openai_*` / `with_anthropic_*` / `with_google_*`     | Compose typed options in the matching `llm_wire/provider/*` module before common configuration                            |
| `types.new_limits` / `new_deadlines`                                       | Update `types.default_limits()` / `default_deadlines()` records; `session.prepare` validates the whole config             |
| Outgoing request checked against `event_bytes_limit`                       | Set `request_bytes_limit` independently; event and request defaults remain 1 MiB                                          |
| Buffered execution or stream opening returns `WireError` directly          | Match `session.RunFailure(error, retry)`; preparation still returns `WireError`                                           |
| Tool-call outcome omitted assistant text                                   | `RunToolCalls(turn, usage)` carries reusable assistant response data                                                      |
| Tool arguments parsed with Blueprint's 10 MiB default                      | Parser byte bounds now follow `argument_bytes_per_call_limit`; depth and number policy stay bounded                       |
| Structured output parsed with Blueprint's 10 MiB default                   | Parser byte bound follows the smaller admitted per-block and total text limits                                            |
| `types.tool_name` returning `WireError`                                    | Match `types.ToolNameError`; names must match `^[a-zA-Z0-9_-]{1,64}$`                                                     |
| `Continuation`, `prepare_continue`, checkpoint APIs, and `provider.Replay` | Append `AssistantTurnMessage(turn)` and results; prepare a new request explicitly                                         |
| Direct internal provider reducer and request hooks                         | Use `provider.Adapter`/`provider.Spec`/`provider.reducer`, then `config.from_provider`; internal transport is unsupported |

## Local release checks

Run these commands from this package in the Gleam/OTP dev shell, with the
sibling Blueprint and Sinal source directories present for the current local
dependencies:

```sh
gleam format --check src test
gleam check
gleam build
gleam test
sh test/external_package_boundary.sh
nix flake check
git diff --check
```

There is no hosted CI workflow yet. It must be added when the release
dependency layout is fixed so a fresh checkout can run these gates.
