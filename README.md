# llm_wire

A bounded LLM client for Gleam on Erlang/OTP. It prepares a request without
I/O, runs or streams it through your own `http_gun.Client`, and returns typed
outcomes and failures. It speaks OpenAI Responses, Anthropic Messages and
Google GenerateContent, and any HTTP/SSE provider you add. The caller owns the
conversation and the tool loop; LLM Wire never retries.

The package targets Gleam 1.18 or newer on Erlang/OTP; the Nix dev shell uses
OTP 28. The JavaScript target is unsupported. Dependencies on HTTP Gun,
Blueprint and Sinal are local path dependencies until those packages publish.

## Make a call

```gleam
import gleam/io
import http_gun
import http_gun/config as http_config
import llm_wire
import llm_wire/openai

pub fn main() -> Nil {
  let assert Ok(client) = http_gun.start(http_config.default())
  let config = openai.new("sk-...") |> openai.config
  let request = llm_wire.request("gpt-5", [llm_wire.user("Hello")])
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  case llm_wire.run(client, prepared) {
    Ok(llm_wire.Answer(text:, ..)) -> io.println(text)
    Ok(_) -> io.println("no final answer")
    Error(failure) -> io.println(llm_wire.describe_failure(failure))
  }
  http_gun.stop(client)
}
```

`anthropic.new(key) |> anthropic.config` and `google.new(key) |> google.config`
select the other built-in providers. `llm_wire.with_endpoint(config, url)`
points a configuration at a compatible server.

`prepare` checks the configuration, messages, tools and schemas and encodes the
body once; it returns a typed `error.PrepareError` and performs no I/O. A
prepared call runs any number of times, for example to retry.

## Defaults

| Setting                                                          | Default                                                              | Setter                                                       |
| ---------------------------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------ |
| whole call, start to final event                                 | 600 s                                                                | `llm_wire.with_call_timeout(config, After(d))`               |
| first token, start to first progress event                       | 180 s                                                                | `llm_wire.with_first_token_timeout`                          |
| idle gap between provider events, after the first progress event | 60 s, reset by every event, including tool-argument deltas and pings | `llm_wire.with_idle_timeout`                                 |
| `next`                                                           | waits for the next event, bounded by the timers above                | `llm_wire.next_within(stream, d)` for a shorter wait         |
| SSE line / event                                                 | 1 MiB / 1 MiB                                                        | `with_limit(config, limit.LineBytes \| limit.EventBytes, n)` |
| request body                                                     | 1 MiB                                                                | `limit.RequestBytes`                                         |
| transport chunk                                                  | 64 KiB                                                               | `limit.ChunkBytes`                                           |
| streamed response                                                | 8 MiB                                                                | `limit.ResponseBodyBytes`                                    |
| non-200 body kept in `error.Status`                              | 64 KiB                                                               | `limit.ErrorBodyBytes`                                       |
| queued progress                                                  | 500 items, 2 MiB                                                     | `limit.QueueCount`, `limit.QueueBytes`                       |
| open blocks                                                      | 64                                                                   | `limit.ActiveBlocks`                                         |
| text per block / per response                                    | 1 MiB / 4 MiB                                                        | `limit.TextBytesPerBlock`, `limit.TotalTextBytes`            |
| tool arguments per call / per response                           | 1 MiB / 4 MiB                                                        | `limit.ArgumentBytesPerCall`, `limit.TotalArgumentBytes`     |
| ids, signatures and replay data                                  | 1 MiB                                                                | `limit.ProviderMetadataBytes`                                |
| unrecognized event name                                          | 16 KiB                                                               | `limit.ExtensionBytes`                                       |
| invalid tool calls                                               | fail the response                                                    | `with_tool_call_checks(config, tool.ReportInvalidToolCalls)` |
| plaintext `http://`                                              | loopback addresses only, decided by HTTP Gun's destination policy    | none                                                         |
| retries and tool rounds                                          | none; `advise` and the caller's loop                                 | none                                                         |
| connect, pool wait, TLS trust, destinations                      | HTTP Gun's client configuration                                      | `http_gun/config`                                            |

`llm_wire.Infinity` lifts a timeout and must be chosen explicitly. Every
timeout is a `gleam/time/duration.Duration`. Each call's whole-call budget
replaces the HTTP Gun client's request timeout and lifts its idle timeout, so a
client default never cuts a long reasoning stream; the client's connect and
pool timeouts, destinations and trust still apply. A limit that is exceeded
fails with `error.LimitExceeded(limit, ..)`, naming the setting that raises it.

## Tools and the conversation

```gleam
import llm_wire
import llm_wire/message
import llm_wire/tool

let weather = tool.new("get_weather", "Current weather", weather_codec)
let request =
  llm_wire.request("gpt-5", [llm_wire.user("Weather in Paris?")])
  |> llm_wire.with_tools([weather])
let assert Ok(prepared) = llm_wire.prepare(config, request)
case llm_wire.run(client, prepared) {
  Ok(llm_wire.NeedsTools(turn:, ..)) -> {
    let results =
      list.map(turn.calls, fn(call) {
        let assert Ok(city) = tool.decode_arguments(call, weather_codec)
        llm_wire.tool_result(call, lookup(city))
      })
    let next = llm_wire.append(request, [message.Assistant(turn), ..results])
    llm_wire.prepare(config, next)
  }
  _ -> todo
}
```

`tool.new` is for declarations in source code and panics, naming the tool, on
a definition bug. `tool.from_contract` and `tool.from_json_schema` (for an MCP
`inputSchema`) take runtime data and return a typed `tool.ToolError`.

An `AssistantTurn` carries the provider's replay data, such as Gemini's signed
parts, in `provider_data`; append it unchanged. Persist conversations with
`message.to_json` / `message.decoder`, or a turn with `message.turn_to_json` /
`message.turn_decoder`. A store that keeps a turn's text and calls itself uses
`turn_replay_to_json` / `turn_replay_decoder(text, calls)`, the format Fabric
stores as `llm_wire.turn.v1`.

With `tool.ReportInvalidToolCalls`, a call to an unknown tool or with invalid
arguments is returned with the others and listed in `NeedsTools.issues`; answer
it with `tool.describe_issue(issue)`.

## Structured output

```gleam
let request =
  llm_wire.request("gpt-5", [llm_wire.user("Extract the invoice")])
  |> llm_wire.with_output("invoice", invoice_codec)
let assert Ok(prepared) = llm_wire.prepare(config, request)
case llm_wire.run(client, prepared) {
  Ok(llm_wire.Answer(output: invoice, ..)) -> save(invoice)
  Error(llm_wire.Failure(error: error.InvalidOutput(raw_output:, failure:), ..)) ->
    reject(raw_output, error.describe_value_failure(failure))
  _ -> todo
}
```

Structured output is the same execution family: only the request changes.
Output that is not valid JSON, fails the schema or fails the codec is a
`Failure` with `error.InvalidOutput`, which keeps the raw text and the typed
reason, and `sent: Completed`.

The output codec must be a record at the root, with every field required. Below
the root, a `codec.union` (a sum type) is accepted on every built-in provider:
it is sent as `anyOf` of strict objects, each with its tag as a single-value
`enum` (`{"tag": "Found", "value": {..}}`; a unit variant has only the tag),
and the reply is decoded by your codec. A union at the root, or with a pair,
number range, optional field or `codec.value()` in a payload, fails `prepare`
with `error.UnsupportedSchema(error.Output, _)`. Providers may not enforce the
tag text exactly (Anthropic documents that `enum` and `const` capitalization is
not guaranteed), so the codec's decoding is the final check. Gemini receives
the schema as `generationConfig.responseJsonSchema`. The nested union was
verified against live Gemini and OpenAI on 2026-10-04; the replies replay
offline from `test/cassettes/live/`.

## Streaming

```gleam
let assert Ok(stream) = llm_wire.stream(client, prepared)
let assert Ok(event) = llm_wire.next(stream)
case event {
  llm_wire.Progress(message.TextDelta(text:, ..)) -> show(text)
  llm_wire.Progress(_) -> Nil
  llm_wire.Done(result) -> finish(result)
}
```

`next` waits for the next event; the call's timers bound the wait.
`next_within(stream, d)` gives up with `TimedOut` and leaves the stream
readable. `collect` reads to the outcome. The process that started the stream
owns it: if it exits, the call is cancelled and its HTTP stream released.
`close` ends the call early and is safe to repeat. Tool-argument deltas arrive
as `message.ToolArgumentsDelta`.

## Failures and retries

A failed call returns `llm_wire.Failure(error:, sent:, partial_output:,
provider:, usage:)`. `sent` is `NotSent`, `MaybeSent` (the provider may have
spent tokens) or `Completed` (the provider finished its response). `error` is
an `error.Error`; `error.Http` carries HTTP Gun's opaque `Failure`, so
`http_gun/error.kind` and `is_retryable` apply to it.

```gleam
case llm_wire.advise(failure) {
  llm_wire.RetryAdvice(llm_wire.MayHelp, delay: llm_wire.ProviderDelay(wait)) ->
    snooze(wait)
  llm_wire.RetryAdvice(llm_wire.MayHelp, delay: llm_wire.Backoff) ->
    retry_with_backoff()
  _ -> give_up(llm_wire.describe_failure(failure))
}
```

`advise` decides from the failure alone: HTTP Gun failures by `Kind`, HTTP
statuses, and provider error codes matched exactly per provider. The `delay`
says who chose the wait. `ProviderDelay(duration)` is the provider's own
`Retry-After`, in delay seconds or as an HTTP date, so a scheduler can snooze
without counting an attempt; LLM Wire does not cap it. `Backoff` means the
provider named no delay and the caller's backoff applies.

A provider's safety stop is a failure, `error.ContentFiltered(stage,
reason)`, with the provider's own reason: OpenAI's `incomplete_details.reason`
`"content_filter"`, Anthropic's `stop_reason` `"refusal"`, Gemini's
`finishReason` (`"SAFETY"`, `"RECITATION"`, ...) or `promptFeedback.blockReason`.
`advise` answers `WillNotHelpUnchanged`: the prompt must change. A model that
declines in its own words (OpenAI's refusal content) is the outcome
`llm_wire.Refused`. `error.kind(error)` classifies every error into a closed
`Kind` (`Transport`, `ProviderError`, `ContentPolicy`, `UnusableResponse`,
`OverLimit`, `Ended`) that gains no variants, for an exhaustive `case`.

## Own the HTTP client

Start one `http_gun.Client` at application startup and pass it to `run` and
`stream`; LLM Wire never starts or stops it. Use `http_gun.supervised` under a
supervisor and `http_gun.named` to reach it. An `http://` endpoint is narrowed
for each call to HTTP Gun's `destination.with_plaintext(PlaintextToLoopbackOnly)`,
so a credential never crosses a network in clear text; a plaintext call to any
other address fails before sending with `DestinationRejected(PlaintextRefused(_))`.

## Add a provider

```gleam
import llm_wire/provider

let config =
  provider.new(message.Custom("acme"), "https://llm.acme.test/v1", encode, fn() {
    provider.reducer(initial_state, step, terminal)
  })
  |> provider.with_headers(fn() { [#("authorization", "Bearer " <> key)] })
  |> provider.config
```

The adapter encodes the admitted request and reduces the event stream; the
runtime keeps transport, timers, limits, tool-call admission, telemetry and
cleanup. The [external provider fixture](test/external_provider.gleam) is a
complete adapter written against public modules only.

## Test without a network

```gleam
import http_gun/config as http_config
import http_gun/testing as http_testing
import llm_wire/testing

let assert Ok(prepared) = llm_wire.prepare(testing.config(), request)
let script =
  http_testing.script([testing.exchange(prepared, testing.text("hello"))])
let assert Ok(client) = http_testing.playback(script, http_config.default())
```

`text`, `tool_calls` (with `tool_call(id:, name:, arguments_json:)`),
`refusal`, `output_limited` and `with_usage` describe a reply. A `Reply` is
opaque. To test code configured for a built-in provider, keep its
configuration: `exchange` lowers the reply into that provider's wire
(`testing.events_for(message.OpenAI, reply)` does it for a fake server).
The failures a provider produces are replies too: `rate_limited`,
`overloaded` and `http_status` write the error status and body of a built-in
provider, `interrupted` cuts a reply off after its content, `stream_error`
ends it with the provider's in-band error event, `content_filtered` and
`prompt_blocked` are the provider's safety stop, and `invalid_output` is a
final text that no schema accepts. `events(chunks)` sends chunks as given,
for a custom wire. `with_retry_after` adds the header to an exchange:

```gleam
let limited =
  testing.exchange(prepared, testing.rate_limited(message.OpenAI))
  |> testing.with_retry_after(duration.seconds(2))
```

A fake HTTP server serves a reply with `testing.http_response(provider,
reply)`, a `gleam/http` response; one that sends an event per chunk reads
`testing.status`, `testing.chunks` and `testing.is_interrupted`. To
feed code that takes a `llm_wire.Failure`, build one with
`testing.failure(provider, error)` instead of running a call. HTTP Gun's
cassettes record and replay the same exchanges.

### Re-record the live cassettes

`test/cassettes/live/` holds replies recorded from the live Gemini and OpenAI
APIs; `test/llm_wire_live_replay_test.gleam` replays them in the gate, offline
and without keys. To re-record, put the keys in `.env.local` at the repository
root, which is git-ignored and never committed:

```sh
GEMINI_API_KEY=...
OPENAI_API_KEY=...
```

Then run `nix develop -c sh dev/record-live`, or name scenarios of
`test/live_scenarios.gleam` (`sh dev/record-live google-tool-call`). Each
scenario makes one small live request and spends tokens; the command is
opt-in and never part of the gate. The keys are read from the environment
and never printed, and HTTP Gun's redaction removes credential headers,
OpenAI account headers and a `key` query parameter before a cassette is
written. Before committing, check that no file contains a key, for example
`grep -rlF "$GEMINI_API_KEY" . --exclude=.env.local --exclude-dir=build`
inside a shell that loaded `.env.local`.

## Observe

`telemetry.event()` is the Sinal event `[llm_wire, observation]`. Its
`Metadata(call:, correlation:, stage:, provider:, outcome:)` names the
execution, the caller's correlation, a fixed stage and outcome, and never
carries content or credentials. Set the correlation once, on the HTTP Gun
view you run the call on: `llm_wire.run(http_gun.with_correlation(client, c),
prepared)`. LLM Wire copies it into its own events, and HTTP Gun's events for
the request carry the same value under the same key.

## Local release checks

```sh
nix develop -c sh dev/gate fast
nix develop -c sh dev/gate full
nix fmt
nix flake check
```

The fast gate checks formatting, the build without warnings, public module
docs and the unit, local H1 and TLS suite. Full adds a clean build, external
consumers and local nghttpd H2 checks. All calls use local or offline inputs;
only `dev/record-live` calls a provider.
The [wave 4 migration guide](docs/migration-wave-4.md) lists every changed
public item.
