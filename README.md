# llm_wire

A bounded LLM client for Gleam on Erlang/OTP. `llm_wire/config` holds provider
and execution settings; `llm_wire/session` prepares, runs, streams, and
collects single interactions. `llm_wire/types` holds the request, message, tool call,
and tool result values shared across those paths. Preparation checks local
options and schemas before a network request.

The package targets Gleam 1.18 or newer on Erlang/OTP. The checked-in Nix
development shell uses OTP 28; other OTP versions have not been verified in
this release candidate. The JavaScript target is unsupported. The current
dependency manifest uses local HTTP Gun, Blueprint and Sinal path dependencies, so the
package is not yet ready for an independent registry install.

The initial release scope and remaining release decisions are recorded in
[CHANGELOG.md](CHANGELOG.md). The exercised behavior is tracked in
[DESIGN-COVERAGE.md](DESIGN-COVERAGE.md).

## Make a call

Build provider options, then compose common execution settings. Preparation
returns `WireError`; execution returns `session.RunFailure(error, retry)` so a
caller can decide whether a request might have reached the provider.

```gleam
import http_gun
import http_gun/config as http_config
import llm_wire/config
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/types

// Start once in application startup; share across independent calls.
// This ceiling must cover the longest configured LLM overall budget.
let http_policy = http_config.Config(..http_config.default(), deadline_ms: 120_000)
let assert Ok(client) = http_gun.start(http_policy)
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
let outcome = session.run(client, prepared)
```

Use `config.anthropic(anthropic.options(key))` or
`config.google(google.options(key))` for the other built-in adapters. Their
provider-specific options live in `llm_wire/provider/anthropic` and
`llm_wire/provider/google`. All three enter the same bounded HTTP/SSE runtime.
`RunText`, `RunToolCalls`, `RunOutputLimited`, and `RunRefusal` are distinct
successful outcomes. The library does not run tools or retry automatically.
`types.ApiKey` holds the key in a closure: `string.inspect` of the key, the
provider options, the config or a prepared call shows a function reference,
never the key.

`types.default_limits()` and `types.default_deadlines()` are bounded records.
Update fields by name and attach them with `config.with_limits` and
`config.with_deadlines`. `request_bytes_limit` bounds the outgoing JSON body;
`event_bytes_limit` independently bounds each incoming SSE event.
`provider_metadata_bytes_limit` bounds retained call IDs, tool names, provider
IDs/state, response IDs, and each response's opaque provider data. Preparation validates all limit and deadline fields before transport.

HTTP policy belongs to client startup. To use a private CA, set
`trust: http_config.CustomCa("certs/local-ca.pem")` in the HTTP policy before
`http_gun.start`. Verification includes the certificate and hostname. LLM Wire
still rejects remote plaintext endpoints; HTTP is admitted only for loopback.
The old per-call CA restriction and pool settings are removed. There is no
replacement for the prerelease idle-connection eviction setting.

HTTP Gun's default destination policy admits public addresses only. A local
model server, such as Ollama on `localhost`, needs a client whose policy allows
loopback; a server on a private network needs `allow_private`. Otherwise every
call fails before submission with `HttpFailure(DestinationRejected)`:

```gleam
import http_gun/destination

let defaults = http_config.default()
let local_policy = http_config.Config(
  ..defaults,
  deadline_ms: 120_000,
  destination: destination.Policy(..defaults.destination, allow_loopback: True),
)
let assert Ok(local_client) = http_gun.start(local_policy)
```

Keep the default policy for clients that reach hosted providers; the loopback
opt-in applies to every request through that client.

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
case session.run(client, prepared) {
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
    session.run(client, next)
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
let result = session.run_structured(client, prepared)
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

let assert Ok(stream) = session.stream(client, prepared)
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

## Own the HTTP client

Prepare remains pure. Pass an explicitly started `http_gun.Client` to `run`,
`stream`, `run_structured`, or `stream_structured`. Calls neither start a hidden
pool nor stop the shared client. Stop it with `http_gun.stop(client)` at
application shutdown. Client shutdown unblocks outstanding calls with typed
failures. Use `http_gun.child(policy)` under an application supervisor and publish
the returned capability through your application registry; a restart supplies a
new client. The [compiled consumer](examples/consumer/src/llm_wire_consumer.gleam)
shows the child specification, concurrent independent calls, and early close.

Each execution starts one absolute overall budget. Admission, connection,
headers and body spend that same budget. Preparing early spends none of it.
HTTP Gun applies the earlier of this deadline and its client ceiling (30 seconds
by default, versus LLM Wire's 60 seconds). Raise the ceiling at startup as shown.
Consumer `ReadTimeout` leaves the stream usable. Semantic idle is independent:
keepalive and non-progress bytes do not reset it. A provider terminal returns
without waiting for HTTP EOF, and closes locally without draining.

Copied stream handles share one cursor. Conflicting reads fail explicitly;
close is idempotent, including concurrent closes. The creating consumer owns the
session lifetime. Its death closes HTTP; copying a handle does not transfer
that lifetime. Use `close` on early exit, including application error paths.
Local close never proves provider cancellation or rollback. See the
[ownership and error mapping](docs/http-gun-migration.md).

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

`Spec.headers` is a closure, `fn() -> List(#(String, String))`, so a
credential inside it never appears in `string.inspect` output or crash reports
of the spec, adapter, config, prepared call or stream. Read the key with
`types.reveal_api_key(key)` inside that closure.
`provider.reveal_headers(adapter)` returns the headers in plain text, for
wrapping one adapter in another; never log its result.

The runtime supplies `Content-Type: application/json`,
`Accept: text/event-stream`, and `Accept-Encoding: identity` for every adapter.
Provider headers add authentication and other provider-specific fields;
attempts to override those fixed protocol headers fail preparation. The
runtime owns transport, deadlines, queue limits, retry evidence, tool catalog
validation, and terminal admission. The runtime bounds returned provider data. Adapters must also bound reducer
state and enforce wire-specific block limits while accumulating a response.

## Choose live, scripted, playback or recording at startup

All modes supply the same `http_gun.Client` to the same session calls. The
[standalone consumer](examples/consumer/README.md) compiles against this checkout
and executes scripted and strict offline playback flows.

`llm_wire/testing` retains pure semantic reply builders and a provider-neutral
`testing.config()`. Lower an opaque prepared call and reply to an HTTP exchange:

```gleam
import http_gun/testing as http_testing
import llm_wire/testing

let assert Ok(call) = session.prepare(testing.config(), request)
let exchanges = [testing.exchange(call, testing.text("hello"))]
let assert Ok(client) = http_testing.start(http_policy, exchanges)
let result = session.run(client, call)
let _ = http_gun.stop(client)
```

`text`, `tool_calls`, `refusal`, `output_limited`, and `with_usage` build semantic
replies. For built-in providers use `testing.Events` with their SSE events or
`testing.Interrupted` for partial failure. `testing.Status` supplies an HTTP
status response. For structured calls use `testing.structured_exchange`.
There is no retained request-history process. Inspect the finite expected
exchanges your test already owns; no additional inspection queue accumulates.

HTTP Gun owns the binary-capable fixture schema and live recorder:

```gleam
import http_gun/cassette
import http_gun/recording

// Offline startup; load errors are explicit and there is no network fallback.
let assert Ok(tape) = cassette.load("fixtures/lookup.json", 8_388_608)
let assert Ok(client) = cassette.playback(tape, http_policy)
// Run your ordinary application flow(client, ...) and stop at shutdown.

// Recording startup opens real HTTP when the application executes calls.
let assert Ok(recorded) = cassette.record(
  http_policy, "fixtures/new.json",
  recording.Options(8_388_608, recording.RefuseExisting),
)
// Run the same flow(recorded.client, ...), consuming or closing every stream.
let captured = recording.finish_wait(recorded.recording, 5000)
let _ = http_gun.stop(recorded.client)
```

Capture/persistence failure is separate from HTTP and semantic outcomes.
`finish_wait` waits for consumed/closed requests and never drains them. Choose
`ReplaceExisting` explicitly when replacing a fixture. Capture is bounded;
publication has atomic visibility, without a power-loss durability promise.

Matching preserves method, target, query, body bytes and significant headers.
Only `authorization`, `proxy-authorization`, `cookie`, `set-cookie`, `x-api-key`,
`api-key`, and `x-goog-api-key` metadata are excluded (case insensitive). Bodies,
queries and unlisted headers remain exact and may contain secrets. Use synthetic
inputs for owned fixtures; body/query redaction is not supplied.
Repeated requests can have distinct sequential replies; mismatches do not consume
the expected exchange. Coordinate admission order when concurrent requests have
different expected replies. Missing/corrupt/incompatible/exhausted fixtures fail
explicitly. Old prerelease LLM Wire cassette files and record-if-missing behavior
are unsupported.

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
content. The `request_sent` stage now carries outcome `http_response_started`
when HTTP Gun returns the response head. It is evidence that the request reached
a response, not an exact wire-submission timestamp; time the entire execution in
the application when measuring end-to-end latency.

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

## HTTP Gun API migration

- Add the unreleased local `http_gun = { path = "../http_gun" }` dependency.
- Change `session.run(call)` to `session.run(client, call)` and likewise for
  streaming and structured execution. Preparation signatures stay unchanged.
- Replace `llm_wire/pool` and `config.with_pool` with application-owned HTTP Gun
  startup/supervision. Move CA and connection policy to that startup.
- Replace the old script process and `llm_wire/cassette` with HTTP Gun scripts,
  playback and recording. Keep LLM semantic reply builders as pure values.
- Match typed `types.HttpFailure(http_gun/error.Reason)`; HTTP opening failures
  arrive as stream terminals because stream setup is asynchronous.

## Local release checks

Run with the local HTTP Gun, Blueprint and Sinal siblings present:

```sh
nix develop -c sh dev/gate fast
nix develop -c sh dev/gate full
nix fmt
nix flake check
```

The fast gate checks formatting, types/build, FFI warnings, production HTTP
boundaries and the complete unit/local H1/TLS suite. Full adds a clean build,
external consumers, independent nghttpd TLS/H2 and simultaneous load. All calls
use synthetic local or offline inputs. See the
[validation report](docs/http-gun-validation.md) for exact runtime, results and
limits. Hosted CI awaits a distributable dependency layout.
