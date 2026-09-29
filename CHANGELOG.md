# Changelog

## Unreleased — initial release candidate

### Included

- **Breaking:** removed `Continuation`, `StructuredContinuation`, all
  `prepare_*continue` and checkpoint APIs, and provider replay closures/codecs.
  `RunToolCalls(turn, usage)` and `StructuredNeedsTools(turn, usage)` return
  `types.AssistantTurn` data. Callers append `AssistantTurnMessage` plus results
  and prepare the next request explicitly. Fabric owns agent state and storage.
- Added bounded version-1 disk cassette playback with strict ordered request
  matching, no network fallback, typed load/format errors, and explicit delivery
  evidence for local mismatches. The same flow uses production or playback
  settings; live recording is deferred.
- Erlang/OTP HTTP and SSE calls through OpenAI Responses, Anthropic Messages,
  Google GenerateContent, and public application-defined provider adapters.
- Pure provider options and common configuration; local admission before
  transport; bounded request, response, progress, metadata, and deadline paths.
- Buffered and owned streaming outcomes, typed retry evidence, exact tool
  response messages, and an optional caller-owned connection pool.
- Blueprint-backed tool and structured-output admission, including schema-only
  tools from finite runtime contracts. Sinal emits fixed lifecycle observations.

### Changed from consumer evidence

Fabric, the first agent-runtime consumer, reported these gaps against the
candidate API.

- **Breaking:** `types.tool_name` returns `Result(ToolName, ToolNameError)` and
  admits only `^[a-zA-Z0-9_-]{1,64}$`, the grammar shared by the built-in
  providers. It no longer trims. A name that every provider would refuse now
  fails at construction instead of at the remote API. A separate typed error
  is simpler than a `WireError` string because a name check has only local
  outcomes. Callers that need a `WireError` map the error explicitly.
  Provider-returned names use the same grammar; a response naming a tool
  outside it fails with `ProtocolError`.
- Added `llm_wire/testing`, a supported deterministic test transport. A
  `Script` serves queued replies to the ordinary session runtime without a
  socket and records each admitted request. `testing.config` selects a
  provider-neutral scripted provider; `testing.with_script` routes any
  configuration, including built-in providers, through raw scripted SSE.
  Downstream packages no longer need a loopback HTTP stub.
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
- Strict response-header rejection is tested, but Gun 2.6.0 has no proven
  16 KiB **pre-allocation** bound on complete headers. The transport decision
  recorded in `DESIGN-COVERAGE.md` remains open before release acceptance.
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

- Select a version and convert local Blueprint and Sinal path dependencies to
  released dependencies. Confirm the repository URL before adding package
  repository metadata.
- Add hosted CI for the final dependency layout and verify the release gates
  there. Current local gates are listed in the README.
- Complete the response-header transport decision and final release review.

No version has been selected or package published.
