# Changelog

## Unreleased — initial release candidate

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
