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
