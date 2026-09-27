# Changelog

## Unreleased — initial release candidate

### Included

- Erlang/OTP HTTP and SSE calls through OpenAI Responses, Anthropic Messages,
  Google GenerateContent, and public application-defined provider adapters.
- Pure provider options and common configuration; local admission before
  transport; bounded request, response, progress, metadata, and deadline paths.
- Buffered and owned streaming outcomes, typed retry evidence, exact tool
  continuation, and an optional caller-owned connection pool.
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
  `session.tool_call_issues` and `session.structured_tool_call_issues`, so an
  agent can answer each bad call instead of losing the turn. Exact result
  coverage still includes reported calls. Built-in reducers no longer check
  the catalog or arguments; the runtime admits every completed batch once, so
  buffered, streamed, built-in, and custom paths apply one rule. Under the
  default, a built-in provider's invalid call now fails when the response
  completes rather than when its block closes.

### Current limits

- The built-in providers cover the documented text, tool, structured-output,
  and selected image profiles. Audio, video, embeddings, realtime/WebSocket,
  batch/background jobs, durable continuation, automatic retries, and remote
  cancellation acknowledgement are outside this candidate.
- Strict response-header rejection is tested, but Gun 2.6.0 has no proven
  16 KiB **pre-allocation** bound on complete headers. The transport decision
  recorded in `DESIGN-COVERAGE.md` remains open before release acceptance.
- Provider replay closures contain adapter-owned state. Adapter authors must
  bound captured state and any wire-specific block structure themselves.

### Known gaps

Fabric reported both gaps. Neither has an accepted contract, so this candidate
records them rather than guessing one.

- **Persistable continuation.** `session.Continuation` lives only in memory.
  It holds an Erlang reference that proves its origin, the retained `Config`
  with credentials and any pool, the admitted catalog with native decode
  closures, and provider replay state: Google raw signed parts and custom
  `provider.Replay` closures. None of it survives a restart, and llm_wire does
  not serialize private state. The design calls for an optional
  provider-owned envelope with identity, version, codec, and compatibility
  outcomes. Restoration must take fresh settings and catalog from the caller,
  keep the pending call IDs and exact result coverage, preserve required
  provider state or reject the envelope as incompatible, and exclude secrets
  and live resources. Until then Fabric persists its own transcript of public
  `types.Message` values, keeping `provider_id` and `provider_state` on each
  call, and rebuilds every turn with `session.prepare`. That path loses Google
  raw non-call parts of a tool turn, custom `Replay` closures (the adapter's
  plain encoder rebuilds the request), and the coverage check of
  `prepare_continue`, which Fabric enforces itself.
- **Retry classification.** `RetryEvidence` states whether a request may have
  reached the provider and whether response bytes or semantic progress were
  observed. It does not state whether another attempt can succeed. Callers
  derive that from `WireError`: Fabric treats `TransportError`,
  `DeadlineExceeded`, and HTTP 408, 429, and 5xx as retryable and everything
  else as final. A library classification would combine the error variant,
  status, provider error codes, `Retry-After`, and retry evidence. It needs
  provider-specific error-code evidence and a ruling on retry ownership, which
  the design keeps separate from agent and workflow retry.

### Release preparation remaining

- Select a version and convert local Blueprint and Sinal path dependencies to
  released dependencies. Confirm the repository URL before adding package
  repository metadata.
- Add hosted CI for the final dependency layout and verify the release gates
  there. Current local gates are listed in the README.
- Complete the response-header transport decision and final release review.

No version has been selected or package published.
