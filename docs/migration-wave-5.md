# Wave 5 migration

Wave 5 closes three follow-ups from the apps: `advise` stops short of a
scheduler's snooze-or-backoff choice, `llm_wire/testing` scripts only
successful streams, and tests build `llm_wire.Failure` by hand. One item
breaks (`RetryAdvice`); the rest is additive, so existing `llm_wire/testing`
call sites keep compiling.

Contents: [advise](#advise) · [testing](#llm_wiretesting) ·
[dependents](#dependents) · [round 6](#round-6)

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
`Events`, `Interrupted` and `Status`, and `events_for`. [Round 6](#round-6)
makes `Reply` opaque.

Behaviour change in the OpenAI reducer: a `response.failed` event used to be
ignored as an unknown extension event, so the stream ended without a terminal.
It now fails the call with `error.Provider(Some(code), message)`, and a
`response.incomplete` event ends the stream as `OutputLimited`. The shapes
follow the pinned fixture (`response.error`, `response.incomplete_details`
fields) and openai-python's `ResponseError`. [Round 6](#round-6) reads
`incomplete_details.reason`, so a content-filter stop is no longer
`OutputLimited`.

## Structured output with a union

Additive: output codecs that failed `prepare` with `UnsupportedSchema` because
of a nested `codec.union` now prepare. The wire form is `anyOf` of strict
objects, `{"tag": {"type": "string", "enum": ["Found"]}, "value": ..}`, with
the fixtures `test/fixtures/structured-union-{openai,anthropic,google}.request.txt`.

| Provider  | Now accepted                                              | Still refused                                            | Basis                                                                                                    |
| --------- | --------------------------------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| OpenAI    | a union below the root (`anyOf`, single-value `enum` tag) | a union at the root                                      | strict mode: root object must not be `anyOf`; nested `anyOf`, `enum` and `const` supported               |
| Anthropic | the same                                                  | the same                                                 | `output_config.format` documents `anyOf`, `const`, `enum` and `additionalProperties: false`; no `oneOf`  |
| Gemini    | the same                                                  | the same; `codec.nullable` stays refused (existing rule) | the structured output guide shows `anyOf` of objects; llm_wire sends `responseSchema`, not verified live |

Payloads must themselves be strict (no optional fields, pairs, number ranges or
`codec.value()`). Tool parameters still refuse unions.

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
| `oversight/apps/research_agent`                                                                                       | Can use `NoSources \| Found(..)` as a nested output (fabric wraps non-object roots in `{"answer": ..}`).                                                                                               |
| `relay`, `warden`, `grind`, `saga`, `sinal`, `json_blueprint`, `http_gun`                                             | Do not import LLM Wire. grind's job worker can match `RetryAdvice` once an app wires `advise` to a snooze.                                                                                             |

## Round 6

Round 6 makes `llm_wire/testing.Reply` opaque (convention 1) and stops
reporting a provider's content filter as `OutputLimited` or `Refused`. Both
break callers; every call site is listed below with its replacement.

### Opaque `Reply` and `ScriptedCall`

| Before                                                                         | After                                                                                                                                                                      |
| ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `testing.Events(chunks)` (construct)                                           | `testing.events(chunks)`: chunks sent as given, in any wire; `events_for` leaves it unchanged                                                                              |
| `testing.Interrupted(chunks)` (construct)                                      | `testing.interrupted(testing.events(chunks))`; `Interrupted([])` is `testing.interrupted(testing.text(""))`                                                                |
| `testing.Status(code, body)` (construct)                                       | `testing.http_status(message.Custom("scripted"), code, body)`: a `Custom` provider sends `body` as is                                                                      |
| `testing.ScriptedCall(id, name, arguments_json)`                               | `testing.tool_call(id, name, arguments_json)` (labels `id:`, `name:`, `arguments_json:` also accepted)                                                                     |
| `case reply { Events(c) -> .. Interrupted(c) -> .. Status(code, body) -> .. }` | `testing.status(reply) -> Int` (200 for a stream), `testing.chunks(reply) -> List(String)` (one per event; `[body]` for a status), `testing.is_interrupted(reply) -> Bool` |
| `let assert testing.Events(chunks) = testing.events_for(p, r)`                 | `let chunks = testing.chunks(testing.events_for(p, r))`                                                                                                                    |
| serve a reply from a fake server                                               | `testing.http_response(provider, reply)` (unchanged), or the three accessors for one chunk per event                                                                       |
| `testing.exchange(prepared, testing.events_for(p, reply))`                     | `testing.exchange(prepared, reply)`: `exchange` now lowers into the prepared provider's wire                                                                               |

`Reply` records its wire. A scripted reply is lowered once by `events_for`,
`exchange` or `http_response`; a lowered reply and one from `events` stay as
they are, so lowering twice is harmless (before, it read the provider's
events as scripted ones and produced an empty stream). `with_usage` applies
before lowering and leaves a lowered reply unchanged.

`testing.refusal(reason)` lowers only to OpenAI (its refusal content) and the
scripted wire; `events_for` panics for Anthropic and Google, whose only
refusal on the wire is the safety stop (`content_filtered`). Before, it
lowered to Anthropic's `stop_reason: "refusal"` and Gemini's
`promptFeedback.blockReason`, which are now `error.ContentFiltered`.

### Call sites

Searched: `/code/gleam-dream/*/src`, `*/test`, `*/integrations`, `*/consumers`,
`*/examples`, `*/experiments` and `/code/gleam-dream/oversight/apps`. Only
these files construct or match `Reply` or `ScriptedCall`; every other user
(`fabric/consumers/decision`, `fabric/consumers/writing`,
`fabric/test/fabric/model_error_test.gleam`, `typed_answer_test.gleam`,
`oversight/apps/extractor`, `oversight/apps/tool_hub/src/tool_hub.gleam` and
`tool_hub/test/tool_hub_test.gleam`) uses builders only and compiles
unchanged. The replacements below were applied to a scratch copy of fabric
and the four apps and compiled against this commit (see the end of this
section).

**`fabric/test/fabric/support/fake_provider.gleam` L71-78** (breaks: matches
the constructors):

```gleam
// Before
/// `testing.http_reply` is private, so the server lowers each reply itself.
fn wire(reply: testing.Reply) -> #(Int, List(String), Bool) {
  case reply {
    testing.Events(chunks) -> #(200, chunks, True)
    testing.Interrupted(chunks) -> #(200, chunks, False)
    testing.Status(code, body) -> #(code, [body], True)
  }
}

// After
/// Each reply as the server sends it: its status, one chunk per event, and
/// whether the response ends (`False` drops the connection first).
fn wire(reply: testing.Reply) -> #(Int, List(String), Bool) {
  #(testing.status(reply), testing.chunks(reply), !testing.is_interrupted(reply))
}
```

**`fabric/test/fabric/llm_test.gleam`**:

| Line                       | Before                               | After                                                                 |
| -------------------------- | ------------------------------------ | --------------------------------------------------------------------- |
| 81, 82, 219, 220, 371, 436 | `testing.ScriptedCall(`              | `testing.tool_call(`                                                  |
| 324                        | `testing.Status(503, "busy")`        | `testing.http_status(message.Custom("scripted"), 503, "busy")`        |
| 342                        | `testing.Status(400, "bad request")` | `testing.http_status(message.Custom("scripted"), 400, "bad request")` |

**`fabric/test/fabric/graph_llm_test.gleam`**:

| Line | Before                                         | After                                                                           |
| ---- | ---------------------------------------------- | ------------------------------------------------------------------------------- |
| 244  | `testing.Interrupted([])`                      | `testing.interrupted(testing.text(""))`                                         |
| 245  | `testing.Status(429, "private response body")` | `testing.http_status(message.Custom("scripted"), 429, "private response body")` |

**`fabric/test/fabric/llm_recovery_test.gleam`**:

| Line | Before                                   | After                                                                     |
| ---- | ---------------------------------------- | ------------------------------------------------------------------------- |
| 86   | `testing.Events([`                       | `testing.events([` (signed Gemini parts, sent as given)                   |
| 339  | `testing.Status(501, "not implemented")` | `testing.http_status(message.Custom("scripted"), 501, "not implemented")` |
| 365  | `testing.Status(503, "busy")`            | `testing.http_status(message.Custom("scripted"), 503, "busy")`            |

**`fabric/test/fabric/llm_turn_format_test.gleam` L224**: `testing.Events([`
→ `testing.events([`.

The `events_for` calls in fabric's tests (`llm_test`, `graph_llm_test`,
`llm_recovery_test`, `llm_turn_format_test`, `typed_answer_test`) keep
working: they lower scripted replies for the loopback fake server, which
serves whatever wire it is given.

**`oversight/apps/tool_hub/src/tool_hub/scripted_llm.gleam`** (add
`import llm_wire/message`):

| Line    | Before                                                                                          | After                                                                                                     |
| ------- | ----------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| 114     | `testing.ScriptedCall(id:, name:, arguments_json: arguments)`                                   | `testing.tool_call(id:, name:, arguments_json: arguments)` (the return type `testing.ScriptedCall` stays) |
| 128     | `respond(testing.Status(500, "script exhausted"))`                                              | `respond(testing.http_status(message.Custom("scripted"), 500, "script exhausted"))`                       |
| 139-143 | `let #(status, chunks) = case reply { testing.Events(..) .. }` and `response.new(status)`       | delete the `case`; `response.new(testing.status(reply))` and `string.concat(testing.chunks(reply))`       |
| 159-162 | `case testing.text("Checking the inventory") { testing.Events([event, ..]) -> event  _ -> "" }` | `case testing.chunks(testing.text("Checking the inventory")) { [event, ..] -> event  [] -> "" }`          |

```gleam
// After, lines 138-147
fn respond(reply: testing.Reply) -> response.Response(mist.ResponseData) {
  response.new(testing.status(reply))
  |> response.set_header("content-type", "text/event-stream")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(string.concat(testing.chunks(reply)))),
  )
}
```

**`oversight/apps/support_desk/src/support_desk/provider.gleam`**:
L94 `testing.ScriptedCall(` → `testing.tool_call(`. L275-292: delete `wire`
and replace `sse` (its `Interrupted | Status -> status(500)` arm cannot
happen: `respond` only builds `text` and `tool_calls` replies):

```gleam
/// The scripted reply as the OpenAI Responses stream llm_wire's own
/// `testing.http_response` writes, with the usage the old fixture reported.
fn sse(reply: testing.Reply) -> Response(mist.ResponseData) {
  testing.with_usage(reply, message.Usage(150, 40, 190))
  |> testing.http_response(message.OpenAI, _)
  |> response.map(fn(body) { mist.Bytes(bytes_tree.from_string(body)) })
}
```

The module doc's mention of `testing.events_for` (L2) may say
`testing.http_response`.

**`oversight/apps/research_agent/src/research_agent/services.gleam` L598**:
`testing.ScriptedCall(` → `testing.tool_call(` (same labels).

### Content filters are `error.ContentFiltered`

| Wire and signal                                                                         | Before                                                      | After                                                                                            |
| --------------------------------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| OpenAI `response.incomplete`, `incomplete_details.reason: "content_filter"`             | `Ok(OutputLimited(..))`                                     | `Error(Failure(error: ContentFiltered(InOutput, "content_filter"), sent: Completed, ..))`        |
| OpenAI `incomplete_details.reason: "max_output_tokens"` or null                         | `OutputLimited`                                             | `OutputLimited` (unchanged)                                                                      |
| OpenAI any other `incomplete_details.reason`                                            | `OutputLimited`                                             | `error.Provider(Some(reason), "Response incomplete with reason: " <> reason)`, advised `Unknown` |
| Anthropic `stop_reason: "refusal"`                                                      | `Ok(Refused(reason: <streamed text>, ..))`                  | `ContentFiltered(InOutput, "refusal")`                                                           |
| Gemini `finishReason` `SAFETY`, `RECITATION`, `BLOCKLIST`, `PROHIBITED_CONTENT`, `SPII` | `Ok(Refused("Google refused generation with reason: X"))`   | `ContentFiltered(InOutput, "X")`                                                                 |
| Gemini `finishReason` `IMAGE_SAFETY`, `IMAGE_PROHIBITED_CONTENT`                        | `error.Provider(Some("X"), "Unknown Google finish reason")` | `ContentFiltered(InOutput, "X")`                                                                 |
| Gemini `promptFeedback.blockReason: X`                                                  | `Ok(Refused("Prompt blocked by safety policy: X"))`         | `ContentFiltered(InPrompt, "X")`                                                                 |
| OpenAI refusal content (`response.refusal.delta`)                                       | `Refused(reason: text)`                                     | `Refused` (unchanged): the model's own words                                                     |

A filter is a failure, not an outcome, because no usable answer exists and
the provider finished its response: `sent` is `Completed`, `partial_output`
says whether text streamed, and `advise` answers
`RetryAdvice(WillNotHelpUnchanged, Backoff)`. This matches OpenAI, which
already rejects a filtered prompt with an error (`invalid_prompt`, advised
`WillNotHelpUnchanged`). `Refused` stays for a model that declines in its own
words.

New in `llm_wire/error`:

```gleam
ContentFiltered(stage: FilterStage, reason: String)   // a new Error variant
pub type FilterStage { InPrompt InOutput }
pub type Kind { Transport ProviderError ContentPolicy UnusableResponse OverLimit Ended }
pub fn kind(error: Error) -> Kind
pub fn kind_name(kind: Kind) -> String   // "content_policy", ...
```

`name` gives `"content_filtered.prompt"` and `"content_filtered.output"`;
`describe` gives `"Provider content filter stopped the output: SAFETY"`.
`Kind` is closed: it gains no variants in a minor release, so a `case` on it
needs no `_` arm. OpenAI chat-style `finish_reason: "content_filter"` has no
counterpart: LLM Wire speaks OpenAI Responses only.

New in `llm_wire/testing`: `content_filtered(partial_text)` (OpenAI
`response.incomplete` with `content_filter`, Anthropic `stop_reason:
"refusal"`, Gemini `finishReason: "SAFETY"`, the scripted wire's
`"content_filter"`) and `prompt_blocked()` (Gemini `promptFeedback.blockReason:
"SAFETY"` and the scripted wire; OpenAI and Anthropic answer such a prompt with
an error status, so `events_for` panics for them). `output_limited` on OpenAI
now ends with `response.incomplete` and `incomplete_details.reason:
"max_output_tokens"`, as the live wire does, instead of `response.completed`
with status `incomplete`.

Sources: openai-python 2.53.0 `types/responses/response.py`
(`IncompleteDetails.reason: Literal["max_output_tokens", "content_filter"]`);
anthropic-sdk-python 0.69.0 `types/stop_reason.py` (`"refusal"`) and
Anthropic's streaming-refusals guide (the classifiers stop the output);
google-genai 1.43.0 `types.py` (`FinishReason`, `BlockedReason`). The pinned
fixture `test/fixtures/openai-responses-long-text.sse` carries
`"incomplete_details": null`, which still reads as complete. No recorded
fixture of a filtered response exists; the reducer tests pin the documented
shapes.

Dependents: no code outside LLM Wire matches `error.Error` without a `_` arm,
so all compile. `fabric/src/fabric/llm.gleam` `failure_of` maps the new error
to `model.Other` (not retryable) through its `_, _` arm; a run that a
Gemini or Anthropic safety stop ends is now `run.Failed(ModelFailed(..))`
instead of `run.Refused(..)`. fabric may want a dedicated `model` kind keyed
on `error.kind(e) == error.ContentPolicy`. `oversight/apps/extractor`
`decide_call` discards it through its `WillNotHelpUnchanged` arm. No test in
fabric or the apps scripts a Gemini or Anthropic safety stop.

Checked: with the call-site replacements above applied to a scratch copy,
fabric's `gleam test` passed (771 tests) and `support_desk`, `research_agent`,
`extractor` and `tool_hub` built against this commit. `tool_hub` needed an
unrelated stub: `src/tool_hub/assistant.gleam` L105
(`server.new([fabric_relay.serve(service)])`) fails to type-check against the
current relay and fabric_relay heads, independently of LLM Wire.
