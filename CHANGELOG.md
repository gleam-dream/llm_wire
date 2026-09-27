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

### Release preparation remaining

- Select a version and convert local Blueprint and Sinal path dependencies to
  released dependencies. Confirm the repository URL before adding package
  repository metadata.
- Add hosted CI for the final dependency layout and verify the release gates
  there. Current local gates are listed in the README.
- Complete the response-header transport decision and final release review.

No version has been selected or package published.
