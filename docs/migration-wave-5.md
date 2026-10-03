# Wave 5 migration

Wave 5 closes three follow-ups from the apps: `advise` stops short of a
scheduler's snooze-or-backoff choice, `llm_wire/testing` scripts only
successful streams, and tests build `llm_wire.Failure` by hand. One item
breaks (`RetryAdvice`); the rest is additive, so existing `llm_wire/testing`
call sites keep compiling.

Contents: [advise](#advise) · [testing](#llm_wiretesting) ·
[dependents](#dependents)

## advise

| Before                                                          | After                                                     |
| --------------------------------------------------------------- | --------------------------------------------------------- |
| `RetryAdvice(prospect: RetryProspect, after: Option(Duration))` | `RetryAdvice(prospect: RetryProspect, delay: RetryDelay)` |
| —                                                               | `RetryDelay { ProviderDelay(Duration) Backoff }`          |

`ProviderDelay(wait)` (named so it cannot be mistaken for grind's
`worker.RetryAfter`, which spends an attempt, where this one snoozes) is a readable `Retry-After` header of the failed response,
in delay seconds or as an HTTP date (a past date is a zero delay). `Backoff`
means the provider named no delay, or the failure had no response headers (a
timer, a cancellation, a stream error). LLM Wire invents no number: the
caller owns its backoff curve. LLM Wire also does not cap `ProviderDelay`, so
bound it before sleeping or scheduling.

```gleam
// Before
case llm_wire.advise(failure) {
  llm_wire.RetryAdvice(llm_wire.MayHelp, after: Some(wait)) -> snooze(wait)
  llm_wire.RetryAdvice(llm_wire.MayHelp, after: None) -> retry_with_backoff()
  _ -> give_up()
}

// After
case llm_wire.advise(failure) {
  llm_wire.RetryAdvice(llm_wire.MayHelp, delay: llm_wire.ProviderDelay(wait)) ->
    snooze(wait)
  llm_wire.RetryAdvice(llm_wire.MayHelp, delay: llm_wire.Backoff) ->
    retry_with_backoff()
  _ -> give_up()
}
```

Code that reads only `advise(failure).prospect` needs no change. A caller that
wants the old `Option` writes
`case advice.delay { ProviderDelay(d) -> Some(d)  Backoff -> None }`.

## `llm_wire/testing`

Every item below is new. Nothing was removed or retyped: `Reply` keeps
`Events`, `Interrupted` and `Status`, and `events_for(provider, reply)`,
`exchange` and the reply builders keep their signatures.

| Item                                                                      | Use                                                                                                                                                                                                                                      |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `rate_limited(provider) -> Reply`                                         | HTTP 429 with the provider's rate-limit body; the call fails with `error.Status(429, ..)`                                                                                                                                                |
| `overloaded(provider) -> Reply`                                           | 529 on Anthropic, 503 elsewhere, with the provider's overload body                                                                                                                                                                       |
| `http_status(provider, status, message) -> Reply`                         | Any error status with a body shaped as the provider shapes errors; a `Custom` provider gets the bare message                                                                                                                             |
| `interrupted(reply) -> Reply`                                             | The connection drops after the reply's content, before its end: a transport failure with `sent: MaybeSent` and `partial_output: True`. Apply it before `events_for`                                                                      |
| `stream_error(provider, reply, code, message) -> Reply`                   | The content streams, then the provider's in-band error event: `error.Provider(Some(code), message)`, `sent: Completed`, `partial_output: True`. The result is already in the provider's wire: pass it to `exchange`, not to `events_for` |
| `response_failed(reply, code, message) -> Reply`                          | OpenAI's `response.failed` event after the content, with `response.error.code` and `message`; same failure as `stream_error(message.OpenAI, ..)`. Already in the OpenAI wire                                                             |
| `invalid_output() -> Reply`                                               | A final text that is not JSON: a plain call answers, a structured call fails with `error.InvalidOutput(raw_output:, ..)`                                                                                                                 |
| `with_retry_after(exchange, delay) -> Exchange`                           | Adds `Retry-After` (whole seconds, a fraction rounds up) to the exchange's response, so `advise` answers `ProviderDelay(delay)`                                                                                                          |
| `http_response(provider, reply) -> gleam/http Response(String)`           | A fake server's response for any reply: status, `content-type` and the joined body. Replaces the `case` on `Events`, `Interrupted` and `Status`                                                                                          |
| `with_retry_after_header(response, delay) -> gleam/http Response(String)` | Adds `Retry-After` (whole seconds, a fraction rounds up) to an `http_response`, for a fake server; the counterpart of `with_retry_after` for exchanges                                                                                   |
| `failure(provider, error) -> llm_wire.Failure`                            | A `Failure` for a test that runs no call; `sent` follows the error, `partial_output` is `False`, `usage` is `None`. Change a field with a record update                                                                                  |

```gleam
// Before: a 429 body written by hand, the header set on the server
let body = json.object([#("error", json.object([#("type", json.string("rate_limit_error"))]))])
response.new(429) |> response.set_header("retry-after", "2")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json.to_string(body))))

// After
testing.exchange(prepared, testing.rate_limited(message.Anthropic))
|> testing.with_retry_after(duration.seconds(2))
// or, for a fake server:
testing.http_response(message.Anthropic, testing.rate_limited(message.Anthropic))
|> response.set_header("retry-after", "2")
```

```gleam
// Before: unwrap, with a branch that cannot happen
let chunks = case testing.events_for(wire, reply) {
  testing.Events(chunks) | testing.Interrupted(chunks) -> chunks
  testing.Status(..) -> []
}

// After
let http = testing.http_response(wire, reply)
```

```gleam
// Before: five fields by hand
llm_wire.Failure(
  error: error.Status(429, "{}", Some(duration.seconds(1))),
  sent: llm_wire.Completed,
  partial_output: False,
  provider: message.OpenAI,
  usage: None,
)

// After
testing.failure(message.OpenAI, error.Status(429, "{}", Some(duration.seconds(1))))
```

Retained, to be removed after the callers below move: the `Reply` constructors
`Events`, `Interrupted` and `Status`, and `events_for`. A later release can
make `Reply` opaque (callers would use the builders and `http_response`).

Behaviour change in the OpenAI reducer: a `response.failed` event used to be
ignored as an unknown extension event, so the stream ended without a terminal.
It now fails the call with `error.Provider(Some(code), message)`, and a
`response.incomplete` event ends the stream as `OutputLimited`. The shapes
follow the pinned fixture (`response.error`, `response.incomplete_details`
fields) and openai-python's `ResponseError`; `incomplete_details.reason` is not
read, so a content-filter stop is also `OutputLimited`.

## Dependents

Searched: `/code/gleam-dream/*/src`, `*/test`, `*/integrations`, `*/consumers`,
`*/examples` and `/code/gleam-dream/oversight/apps`.

| Dependent                                                                                                             | Effect                                                                                                                                                                                                 |
| --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `oversight/apps/extractor/src/extractor/outcome.gleam` (L100-111)                                                     | **Breaks**: matches `RetryAdvice(MayHelp, after:)` and `RetryAdvice(.., ..)`. Match `delay: ProviderDelay(wait)` for the snooze arm and `delay: Backoff` for the default-snooze arm.                   |
| `oversight/apps/extractor/src/extractor/scripted.gleam` (L190-260)                                                    | Compiles. `provider_error` (43 lines) becomes `testing.http_status` / `rate_limited` / `overloaded`; `sse`'s `case` becomes `testing.http_response`.                                                   |
| `oversight/apps/extractor/test/extractor_test.gleam` (L219, 289, 297, 445, 532)                                       | Compiles. The five hand-built `llm_wire.Failure(..)` can use `testing.failure`.                                                                                                                        |
| `oversight/apps/tool_hub/src/tool_hub/scripted_llm.gleam` (L132-136)                                                  | Compiles. `respond` can use `testing.http_response(message.Custom("scripted"), reply)`.                                                                                                                |
| `oversight/apps/support_desk/src/support_desk/provider.gleam` (L262-280)                                              | Compiles. `wire` and `sse` become `testing.http_response(message.OpenAI, reply)`.                                                                                                                      |
| `oversight/apps/research_agent/src/research_agent/services.gleam` (L525-531)                                          | Compiles. The `let assert testing.Events(chunks)` becomes `testing.http_response(..).body`.                                                                                                            |
| `fabric/src/fabric/llm.gleam` (L148)                                                                                  | Compiles. Reads `advise(failure).prospect` only.                                                                                                                                                       |
| `fabric/test/fabric/support/fake_provider.gleam`, `llm_test.gleam`, `graph_llm_test.gleam`, `llm_recovery_test.gleam` | Compile. They match `Events`, `Interrupted`, `Status` exhaustively, so `Reply` gained no variant. `Interrupted([])` and `Status(429, ..)` in `graph_llm_test` can use `interrupted` and `http_status`. |
| `relay`, `warden`, `grind`, `saga`, `sinal`, `json_blueprint`, `http_gun`                                             | Do not import LLM Wire. grind's job worker can match `RetryAdvice` once an app wires `advise` to a snooze.                                                                                             |
