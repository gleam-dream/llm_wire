# Changelog

## Unreleased — initial release candidate

### Changed in wave 5

[docs/migration-wave-5.md](docs/migration-wave-5.md) lists each item with
its dependents.

- **Breaking:** `RetryAdvice(prospect, after: Option(Duration))` became
  `RetryAdvice(prospect, delay: RetryDelay)`. `RetryDelay` is
  `RetryAfter(Duration)`, the provider's own `Retry-After`, or `Backoff`, no
  provider delay. A scheduler that snoozes for a provider's delay and backs
  off otherwise (grind) matches on it directly. `advise(failure).prospect` is
  unchanged.
- `llm_wire/testing` scripts a provider's failures: `rate_limited(provider)`,
  `overloaded(provider)` and `http_status(provider, status, message)` write
  the error status and body of OpenAI, Anthropic and Google; `interrupted`
  cuts a reply off after its content; `invalid_output` is a final text no
  schema accepts; `with_retry_after` adds `Retry-After` to an exchange.
  `events_for` passes these replies through unchanged.
- `testing.stream_error(provider, reply, code, message)` streams `reply`, then
  the wire's own in-band error event (OpenAI and Anthropic `event: error`,
  Gemini's `error` payload, the scripted wire's `error` event). The call fails
  with `error.Provider(Some(code), message)`, `sent: Completed`.
- The OpenAI reducer reads `response.failed` (and a `response.completed` with
  status `failed`): `error.Provider(Some(response.error.code),
response.error.message)`, classified by `advise` like `event: error`. A
  `response.incomplete` event ends the stream as an output limit.
  `testing.response_failed(reply, code, message)` scripts the failed form.
- `testing.http_response(provider, reply)` is a `gleam/http` response for a
  fake server, so no caller unwraps `Events`, `Interrupted` and `Status`.
- `testing.failure(provider, error)` builds a `llm_wire.Failure` for tests
  that do not run a call.
- Existing `testing` items are unchanged: `Reply`, `events_for` and
  `exchange` keep their types.

### Changed in the wave 4 API redesign

Every public module changed; [docs/migration-wave-4.md](docs/migration-wave-4.md)
maps each removed item to its replacement.

- **Breaking (LLM-R6, R2):** one root module, `llm_wire`, replaces `session`,
  `config` and `retry`. One execution family serves plain and structured
  output: `request` returns `Request(String)` and `with_output(name, codec)`
  turns it into `Request(o)`; `prepare`, `run`, `stream`, `next`, `collect` and
  `close` take any `Prepared(o)`/`Stream(o)`. The seven `_structured` twins,
  `Structured*` results and the second `ReadError` are gone. `Outcome(o)` is
  `Answer(output, text, usage)`, `NeedsTools(turn, issues, usage)`,
  `OutputLimited` or `Refused`; a stream yields `Progress(p)` then `Done(result)`.
- **Breaking (LLM-R1):** three timers with D5 defaults: whole call 600 s, first
  token 180 s from the start to the first progress event, idle gap 60 s
  between provider events, reset by every event including tool-argument
  deltas and pings. `next` waits for an event instead of polling every 5 s;
  `next_within(stream, Duration)` gives up with `TimedOut`. Every timeout is a
  `gleam/time/duration.Duration` behind `with_call_timeout`,
  `with_first_token_timeout` and `with_idle_timeout`, and `Infinity` lifts one
  explicitly. Reducers emit `message.ToolArgumentsDelta`. Each call's budget
  still replaces the HTTP Gun client's request timeout and lifts its idle
  timeout. The SSE line limit stays 1 MiB.
- **Breaking (LLM-R4):** typed failures. `error.Error` (`Http`, `Status`,
  `Provider`, `Protocol`, `LimitExceeded(limit.Limit, ..)`,
  `DeadlineExceeded(Timeout)`, `Cancelled`, `InvalidOutput(raw_output,
ValueFailure)`, `Stopped`) replaces `WireError` at execution;
  `error.PrepareError` (`InvalidSetting`, `InvalidRequest`, `UnsupportedSchema`,
  `ToolResultMismatch`, `RequestTooLarge`) replaces it at preparation, with no
  strings to parse. Invalid structured output is a failure that keeps the raw
  text and the typed reason, with `sent: Completed`. `error.Http` carries
  HTTP Gun's opaque `Failure` (wave 3 follow-up), so its `Kind`, `is_retryable`,
  `status` and headers apply directly.
- **Breaking (LLM-R3):** `advise(failure)` replaces `retry.assess(provider,
error)`. `Failure(error, sent, partial_output, provider, usage)` carries the
  provider, `NotSent`/`MaybeSent`/`Completed` evidence and the last usage.
  HTTP Gun failures are classified by `Kind`, and `RetryAdvice.after` is the
  `Retry-After` delay, from seconds or an HTTP date.
- **Breaking (LLM-R5):** callers build only opaque values. `Config`,
  `Request(o)`, `Prepared(o)`, `Stream(o)`, `tool.Tool` and adapters are opaque;
  limits are set with `with_limit(config, limit.Limit, Int)`; keys, models and
  endpoints are strings validated by `prepare`. API keys stay in closures.
- **Breaking (LLM-R6):** messages live in `llm_wire/message`: `System`, `User`,
  `UserParts`, `Assistant(turn)`, `AssistantParts`, `ToolResult` replace nine
  variants; ids and tool names are strings; `AssistantTurn.provider` is
  optional for application-written turns.
- **LLM-R7:** `message.to_json`/`decoder`, `turn_to_json`/`turn_decoder` and
  `turn_replay_to_json`/`turn_replay_decoder(text, calls)`. The replay format is
  Fabric's stored `llm_wire.turn.v1` data, and earlier Fabric records decode.
- **Breaking (LLM-R8):** `telemetry.event()` replaces `observation_event()`;
  `Metadata(call, correlation, stage, provider, outcome)` names each execution
  and copies the correlation of the `http_gun.Client` view the call ran on
  (`http_gun.correlation`), so a caller sets it once, with
  `http_gun.with_correlation`. `prepare` emits nothing; execution starts with `Started`.
- **Breaking (LLM-R9):** `tool.new(name, description, codec)` is total and
  panics on a definition bug; `tool.from_contract` and `tool.from_json_schema`
  take runtime schemas; `tool.decode_arguments` decodes a call.
- **LLM-R10:** the host-string plaintext checks are gone. A plaintext call's
  HTTP Gun view uses `destination.with_plaintext(PlaintextToLoopbackOnly)`, so
  plaintext to any resolved non-loopback address fails before sending, and
  `http://[::1]:port` endpoints work.
- **LLM-R11:** `testing.events_for(provider, reply)` lowers a scripted reply
  into the OpenAI, Anthropic or Gemini wire. `testing.exchange` covers every
  `Prepared(o)`; `structured_exchange` is removed and `http_reply` is private.
- **Breaking:** `llm_wire/provider` builds adapters with `provider.new` and
  `with_headers`, `with_tool_schema`, `with_output_schema`; reducers have no
  retry callback and terminals are built with `provider.text`, `tool_calls`,
  `output_limited`, `refused` and `failed`. Provider options moved to
  `llm_wire/openai`, `anthropic` and `google`.
- New dependency: `gleam_time >= 1.11.0 and < 2.0.0`.

### Changed for the release API review

- **Breaking:** API keys no longer print. `types.ApiKey` stores the key in a
  closure, so `string.inspect` and crash reports of the key, provider options,
  `config.Config`, `provider.Adapter`, prepared calls, streams and fixture
  exchanges show a function reference instead. `provider.Spec.headers` is now
  `fn() -> List(#(String, String))`; a custom adapter writes
  `headers: fn() { [...] }`. `provider.headers` is replaced by
  `provider.reveal_headers`, and the new `types.reveal_api_key` is the explicit
  accessor a custom adapter uses to build its credential header.
- The default `line_bytes_limit` is 1 MiB (was 16 KiB), equal to
  `event_bytes_limit`. OpenAI replies over about 16 KB failed with
  `ResourceLimitExceeded("line_bytes_limit", 16384, _)`, because
  `response.output_text.done`, `response.output_item.done` and
  `response.completed` repeat the whole text on one SSE line; a Gemini
  function call over 16 KiB failed the same way. The limit stays
  configurable. The SSE framer now resumes its line scan where the previous
  chunk ended, so a long line costs linear rather than quadratic time.
- Every public module now starts with a rendered `////` module doc that states
  its responsibility and its relation to the other modules; `config` and
  `session` include an example checked against the current API. `dev/gate` fails when a
  public module lacks one.

- **Breaking:** migrated to the Sinal and Blueprint wave 2 APIs.
  `types.tool_from_contract` takes a `json/blueprint/contract.Contract`
  (was `runtime.RuntimeContract`). Tool schemas expose Blueprint's
  `UnionSchema` instead of `FieldSchema`/`TaggedSchema`. Discovered and
  structured values convert to JSON exactly through `value.to_json`, replacing
  a bridge that went through `Float` and could lose precision. The text of
  `OutputValidationError`, `InvalidArguments` and `PreparationError` reasons
  now uses Blueprint's `describe_*` wording instead of inspected Gleam values.
  `telemetry.observation_event()` keeps its type; subscribe with
  `sinal.observe(event, run)`.

- **Breaking:** migrated to the HTTP Gun wave 3 API. `testing.exchange`,
  `testing.structured_exchange` and `testing.http_reply` return
  `http_gun/testing.Exchange` and `http_gun/testing.Reply` (were
  `http_gun/fixture`); give them to `http_gun/testing.playback` with
  `testing.script`. `types.HttpFailure` still carries `http_gun/error.Reason`,
  whose variants follow HTTP Gun (for example `PlaybackExhausted`,
  `PlaybackMismatch`, `IdleTimeout`). Each call now sends through an HTTP Gun
  view: its overall budget replaces the client's request timeout, and the
  client's idle timeout is lifted, so HTTP Gun's 30 s defaults no longer cut
  the 60 s budget or a slow first token. Applications drop the raised
  `deadline_ms` ceiling. The test cassette is converted to schema 2.

### Included

- **Breaking:** removed `Continuation`, `StructuredContinuation`, all
  `prepare_*continue` and checkpoint APIs, and provider replay closures/codecs.
  `RunToolCalls(turn, usage)` and `StructuredNeedsTools(turn, usage)` return
  `types.AssistantTurn` data. Callers append `AssistantTurnMessage` plus results
  and prepare the next request explicitly. Fabric owns agent state and storage.
- **Breaking:** execution now takes an application-owned `http_gun.Client`.
  Removed the direct Gun transport, custom pool, per-call CA/pool settings and
  duplicate HTTP cassette engine. Pure preparation and caller-owned histories
  remain unchanged. Trust and transport limits belong to HTTP client startup.
- HTTP Gun provides binary fixtures, strict offline playback and actual live
  recording through the same session path. Capture/persistence failures are
  separate; finite capture, explicit replacement and no-drain finalization are
  tested. The old prerelease fixture schema is removed.
- Erlang/OTP HTTP and SSE calls through OpenAI Responses, Anthropic Messages,
  Google GenerateContent, and public application-defined provider adapters.
- Pure provider options and common configuration; local admission before
  transport; bounded request, response, progress, metadata, and deadline paths.
- Buffered and owned streaming outcomes, typed retry evidence, exact tool
  response messages, and an explicitly shared application-owned HTTP Gun client.
- Blueprint-backed tool and structured-output admission, including schema-only
  tools from finite runtime contracts. Sinal emits fixed lifecycle observations.

### Changed from consumer evidence

Fabric, the first agent-runtime consumer, reported these gaps against the
candidate API.

- `gleam_stdlib` is now `>= 0.70.0 and < 2.0.0` (was `< 1.0.0`), so an
  application can combine LLM Wire with packages that need `gleam_stdlib` 1.x.
  The dev dependency `simplifile` is `>= 2.7.0 and < 3.0.0` instead of an exact
  pin. The manifests resolve `gleam_stdlib` 1.0.5; no source change was needed.

- **Breaking:** `types.tool_name` returns `Result(ToolName, ToolNameError)` and
  admits only `^[a-zA-Z0-9_-]{1,64}$`, the grammar shared by the built-in
  providers. It no longer trims. A name that every provider would refuse now
  fails at construction instead of at the remote API. A separate typed error
  is simpler than a `WireError` string because a name check has only local
  outcomes. Callers that need a `WireError` map the error explicitly.
  Provider-returned names use the same grammar; a response naming a tool
  outside it fails with `ProtocolError`.
- `llm_wire/testing` retains pure semantic reply builders and lowers admitted
  prepared calls to HTTP Gun exchanges. There is no separate script process,
  connector or request-history buffer.
- Added `config.with_tool_call_checks` with `types.ToolCallChecks`. The default,
  `RejectInvalidToolCalls`, keeps the documented contract: an undeclared tool
  or invalid arguments fail the response with `ProtocolError`.
  `ReportInvalidToolCalls` returns every call and exposes
  `types.ToolCallIssue` values (`UnknownTool`, `InvalidArguments`) through
  `AssistantTurn.issues`, so an
  agent can answer each bad call instead of losing the turn. Exact result
  coverage still includes reported calls. Built-in reducers no longer check
  the catalog or arguments; the runtime admits every completed batch once, so
  buffered, streamed, built-in, and custom paths apply one rule. Under the
  default, a built-in provider's invalid call now fails when the response
  completes rather than when its block closes.
- A reported call now replays to every built-in provider, through
  caller-owned messages given to `session.prepare`.
  Anthropic `input` and Google `args` must be JSON objects, so their encoders
  send argument text that is not a JSON object, such as truncated JSON, as
  `{"unparsed_arguments": text}`. The model still sees what it sent, and the
  caller no longer rewrites the call. OpenAI carries arguments as a string and
  replays the text verbatim, as before. Preparation no longer fails with
  `PreparationError("Continuation contains invalid tool argument JSON")`, and
  a valid non-object value such as `[1]` is wrapped rather than sent to a
  provider that refuses it. The encoding does not depend on
  `ToolCallChecks`; under the default, responses are admitted and
  new responses are checked against the current catalog.

### Current limits

- The built-in providers cover the documented text, tool, structured-output,
  and selected image profiles. Audio, video, embeddings, realtime/WebSocket,
  batch/background jobs, automatic retries, and remote
  cancellation acknowledgement are outside this candidate.
- HTTP Gun/Gun apply documented HTTP limits. Released, unmodified Gun/Cowlib
  remain underneath; protocol-parser pre-allocation certification is outside this
  migration and is not a new release blocker. No universal memory claim is made.
- Adapter authors must bound reducer state and wire-specific block structure.
  Returned provider data is bounded by the runtime.

### Provider messages and retry assessment

- Google raw signed parts stay with their own assistant turn. Multiple caller-
  supplied turns retain their signatures, including signed text followed by an
  unsigned round. Repeated call IDs resolve result names and provider IDs within
  their own round. Invalid raw/normalized combinations fail preparation.
- Request-local validation rejects missing, duplicate, unknown and orphan tool
  results before transport. Reported invalid arguments keep their established
  provider encoding. There is no retained source request or implicit agent loop.
- `retry.assess` returns `MayHelp`, `WillNotHelpUnchanged`, or `Unknown`. The
  caller owns retry policy and repeated effects.
- Updated Dream/ReqCassette oracle mappings to cassette behavior. Added
  [Fabric migration notes](docs/fabric-migration.md) for caller-owned histories,
  persistence, tool result association and injectable test configuration.

### Release preparation remaining

- Select a version and convert local HTTP Gun, Blueprint and Sinal path dependencies to
  released dependencies. Confirm the repository URL before adding package
  repository metadata.
- Add hosted CI for the final dependency layout and verify the release gates
  there. Current local gates are listed in the README.
- Complete the final release/API review; migration validation is recorded in
  `docs/http-gun-validation.md` for Darwin ARM64 OTP 28 only.

No version has been selected or package published.
