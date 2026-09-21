# LLM Wire Wave 1 Implementation Report

## 1. Repository and Toolchain Baseline

- **Repository**: `/code/gleam-dream/llm_wire`
- **Initial Git State**: Unborn `master` branch; zero existing commits; zero configured remotes.
- **Sibling Repositories**:
  - `/code/gleam-dream/relay`: Preserved pre-existing uncommitted dependency additions in `gleam.toml` and `manifest.toml` as instructed. Sibling repositories were treated as strictly read-only.
  - `/code/gleam-dream/oversight`: Read-only design specifications and work order references.
  - `/code/gleam-dream/json_blueprint`: Local path dependency at commit `d3f0708b61eddb4a4789c0476ab5384267814a51`.
  - `/code/gleam-dream/sinal`: Local path dependency at commit `dd09933e5466628f7d46fa896c389f31ba7d4cb6`.
- **Toolchain Versions**:
  - Gleam: 1.18.1
  - Erlang/OTP: 28.3
  - rebar3: 3.27.0
  - Language Server: `/etc/profiles/per-user/edgar/bin/agent-lsp` (invoked cleanly without Nix banner contamination).
- **Target Platform**: Erlang/OTP. No premature claims of JavaScript runtime support are made.

---

## 2. Changed Files and Exported API Map

### Changed Files

- Scaffold and Toolchain:
  - `gleam.toml`: Package definition for `llm_wire`, targeting Erlang with path dependencies `json_blueprint` and `sinal`.
  - `flake.nix`, `flake.lock`: Nix development shell with Erlang 28, Gleam 1.18.1, rebar3, lefthook, and treefmt (`gleam`, `nixfmt`, `prettier`).
  - `.gitignore`, `.envrc`, `lefthook.yml`, `AGENTS.md`, `CLAUDE.md`, `README.md`.
  - `WAVE-1-PROGRESS.md`, `DESIGN-COVERAGE.md`.
- Implementation (`src/`):
  - `src/llm_wire.gleam`: Public facade exposing domain types, checked constructors, and stream client functions.
  - `src/llm_wire/types.gleam`: Domain types, checked opaque constructors, error definitions, resource bounds, and retry classifications.
  - `src/llm_wire/sse.gleam`: Pure streaming SSE framer consuming arbitrary `BitArray` slices with pre-allocation byte limits.
  - `src/llm_wire/openai.gleam`: OpenAI Responses wire event decoder and semantic reducer.
  - `src/llm_wire/anthropic.gleam`: Anthropic Messages wire event decoder and semantic reducer.
  - `src/llm_wire/owner.gleam`: OTP Stream Owner actor enforcing single active read credit, timer deadlines, queue limits, and idempotent cleanup.
  - `src/llm_wire/tcp.gleam`: Erlang `:gen_tcp` interface for client and server sockets.
  - `src/llm_wire_tcp_ffi.erl`: Erlang FFI implementation for non-blocking `:gen_tcp` socket operations.
  - `src/llm_wire/transport.gleam`: Real TCP client streaming loop with credit-based consumer backpressure.
  - `src/llm_wire/client.gleam`: Stream openers `open_openai_stream` and `open_anthropic_stream`.
- Testing and Verification (`test/`):
  - `test/llm_wire_types_test.gleam`: 7 unit tests for checked constructors and validation bounds.
  - `test/llm_wire_sse_test.gleam`: 11 unit tests for byte fragmentation, UTF-8 split code points, multiline data, and limits.
  - `test/llm_wire_openai_test.gleam`: 5 unit tests for interleaved items, concurrent tool calls, and limits.
  - `test/llm_wire_anthropic_test.gleam`: 8 unit tests for content blocks, tool arguments, cumulative usage snapshots, and limits.
  - `test/llm_wire_owner_test.gleam`: 7 unit tests for reader serialization, copied handles, deadlines, and caller death cleanup.
  - `test/fake_server.gleam`: In-process loopback HTTP/SSE server supporting controlled chunk delivery and disconnects.
  - `test/llm_wire_integration_test.gleam`: 5 end-to-end integration tests over real loopback TCP sockets.
  - `test/oracle/README.md`: Behavioral oracle and derivation ledger for ReqLLM v1.24.0, Jido AI v2.3.0, and provider documentation.

### Exported Public API Map (`src/llm_wire.gleam` and `src/llm_wire/types.gleam`)

- **Domain Identity**:
  - `ModelId`, `model_id(String) -> Result(ModelId, WireError)`, `model_id_to_string(ModelId) -> String`
  - `CallId`, `call_id(String) -> Result(CallId, WireError)`, `call_id_to_string(CallId) -> String`
  - `ToolName`, `tool_name(String) -> Result(ToolName, WireError)`, `tool_name_to_string(ToolName) -> String`
  - `ApiKey`, `api_key(String) -> Result(ApiKey, WireError)`, `api_key_expose(ApiKey) -> String` (redacted in `string.inspect`)
  - `Endpoint`, `endpoint(String) -> Result(Endpoint, WireError)`, `endpoint_to_string(Endpoint) -> String`
- **Resource and Deadline Configurations**:
  - `Limits`, `new_limits(...) -> Result(Limits, WireError)`, `default_limits() -> Limits`
  - `Deadlines`, `new_deadlines(...) -> Result(Deadlines, WireError)`, `default_deadlines() -> Deadlines`
- **Errors and Outcomes**:
  - `WireError`: `ConfigurationError`, `PreparationError`, `TransportError`, `HttpStatusError`, `ProviderError`, `ProtocolError`, `ResourceLimitExceeded`, `DeadlineExceeded`, `CancellationError`, `OutputValidationError`
  - `ReadResult`: `NextProgress(StreamProgress)`, `StreamTerminal(TerminalOutcome)`
  - `StreamProgress`: `TextDelta`, `ReasoningDelta`, `ToolCallCompleted`, `UsageUpdate`, `ProviderExtension`
  - `TerminalOutcome`: `CompletedText`, `ToolCalls`, `OutputLimited`, `Refusal`, `StreamFailed`, `StreamCancelledLocally`
  - `RetryEvidence`: `RetryEvidence(classification, response_bytes_observed, semantic_progress_observed)`
  - `RetryClassification`: `NoRequestSent`, `RequestMayHaveReachedProvider`, `EffectUnknown`
- **Stream Operations**:
  - `Stream`: Opaque handle to owner actor.
  - `open_openai_stream(...) -> Result(Stream, WireError)`
  - `open_anthropic_stream(...) -> Result(Stream, WireError)`
  - `next(Stream, timeout_ms) -> Result(ReadResult, ReadError)`
  - `close(Stream) -> Result(CloseOutcome, ReadError)`

---

## 3. Streaming Pipeline and Enforced Resource Bounds

### Pipeline Architecture

```text
Transport TCP Bytes
  -> pure bounded SSE Framer (`src/llm_wire/sse.gleam`)
  -> complete SSE events (`ServerSentEvent(event, data, id, retry)`)
  -> provider semantic Reducer (`src/llm_wire/openai.gleam` | `src/llm_wire/anthropic.gleam`)
  -> single OTP Stream Owner (`src/llm_wire/owner.gleam`)
  -> one serialized, credited consumer read (`owner.next(stream, timeout_ms)`)
```

### Pre-Allocation Resource Bounds

Every memory buffer is bounded by explicit limits checked before appending incoming bytes:

1. `chunk_bytes_limit`: Rejects oversized transport chunks immediately.
2. `line_bytes_limit`: Prevents memory exhaustion from unbounded SSE field lines.
3. `event_bytes_limit`: Limits total accumulated data across multiline SSE events.
4. `queue_count_limit` & `queue_bytes_limit`: Limits pending semantic events in owner actor mailbox.
5. `active_blocks_limit`: Limits concurrent open text and tool call blocks.
6. `text_bytes_per_block_limit` & `total_text_bytes_limit`: Bounds total received text.
7. `argument_bytes_per_call_limit` & `total_argument_bytes_limit`: Bounds tool call argument accumulators.
8. `extension_bytes_limit`: Restricts diagnostic payload retention for unknown provider extensions.

---

## 4. Provider Fixture and Oracle Provenance

- **ReqLLM v1.24.0 Oracle**:
  - Source Commit: `fd9e079fddf253e9b719b2d2c6920f4306592809` (tag `29f855513c327ec5630a16215531ad2d459ae56e`), Apache-2.0.
  - Process ownership, single outstanding reader semantics, credit flow, and retry constraints ported.
  - Unbounded string concatenation and parser error tolerance in ReqLLM were intentionally replaced with strict typed failures and bounded limits.
- **Jido AI v2.3.0 Oracle**:
  - Tag `d368f2f25228a7499030c1dea08d3d284cf6ceaa`, Apache-2.0.
  - Verified lockfile pins ReqLLM 1.17.1. ReAct runner streaming loops excluded as host responsibilities.
- **Provider Protocol Fixtures**:
  - OpenAI Responses: Protocol observed 2026-09-20. Covers `response.output_item.added`, `response.output_text.delta`, `response.function_call_arguments.delta`, `response.output_item.done`, `response.completed`, `error`.
  - Anthropic Messages: Protocol observed 2026-09-20. Covers `message_start`, `content_block_start`, `content_block_delta`, `content_block_stop`, `message_delta`, `message_stop`, `ping`, `error`.
- Full ledger recorded in `test/oracle/README.md`.

---

## 5. Recorded Red-Green Cycles

Representative red-green progression across major subsystems:

1. **Domain Types and Checked Constructors**:
   - Red: Missing `types.api_key("")` validation failing to reject empty secrets.
   - Green: `types.api_key` constructor returning `Error(ConfigurationError("API key cannot be empty"))`.
2. **Pure SSE Framer Split UTF-8**:
   - Red: Framer failing on 4-byte emoji code point split byte-by-byte across 4 `BitArray` chunks with UTF-8 decoding error.
   - Green: Preserving byte buffer until complete UTF-8 boundary before string parsing.
3. **OpenAI Interleaved Output Items**:
   - Red: Second `response.output_item.added` overwriting previous item buffer.
   - Green: Reducer tracking items by `output_index` and accumulating distinct buffers.
4. **Anthropic Cumulative Usage Snapshot**:
   - Red: Summing cumulative `output_tokens` on successive `message_delta` events resulting in incorrect token counts.
   - Green: Replacing token count snapshot with newest value.
5. **OTP Owner Single-Reader Concurrency**:
   - Red: Two simultaneous calls to `owner.next` both racing mailbox.
   - Green: Second caller receiving immediate deterministic `Error(ConcurrentReadConflict)`.
6. **Real Loopback Transport Mid-Stream Disconnect**:
   - Red: Reader actor panicking on `Cannot receive with a subject owned by another process`.
   - Green: Spawning reader process with child-owned subject and attaching transport via actor message passing.

---

## 6. Verification Gates and Coverage Evidence

All required project verification commands were run and passed cleanly:

1. `nix develop --command gleam format --check src test`:
   - Status: Exit code 0. Clean formatting.
2. `nix develop --command gleam check --target erlang`:
   - Status: Exit code 0. Clean compilation.
3. `nix develop --command gleam test --target erlang`:
   - Status: Exit code 0. **43 tests passed, 0 failures**.
4. `nix fmt`:
   - Status: Exit code 0. Treefmt formatted all tracked files.
5. `nix flake check`:
   - Status: Exit code 0. Flake checks passed.
6. `git diff --check`:
   - Status: Exit code 0. Zero trailing whitespace or merge conflict markers.
7. `git status --short --branch`:
   - Status: Exit code 0. Uncommitted intent-to-add tree on unborn `master`. Zero remotes configured.

---

## 7. Local Fake HTTP Test Evidence

In `test/llm_wire_integration_test.gleam`, real TCP loopback client-server exchanges were executed:

- **`real_http_openai_streaming_test`**: Validated real HTTP POST exchange, SSE header negotiation, and stream reduction of multiple text deltas and usage update.
- **`real_http_anthropic_streaming_test`**: Validated real HTTP POST exchange with `x-api-key`, tool use argument fragment assembly over TCP, and cumulative usage update.
- **`real_http_429_error_test`**: Validated rejection and socket closure on HTTP 429 Too Many Requests status before stream setup.
- **`real_http_disconnect_mid_stream_test`**: Validated socket abrupt drop after text delta; verified `semantic_progress_observed: True` and non-retryable classification `RequestMayHaveReachedProvider`.
- **`real_http_disconnect_before_bytes_test`**: Validated socket abrupt drop before response headers; verified `response_bytes_observed: False` and non-retryable classification `RequestMayHaveReachedProvider`.

---

## 8. Sibling Dependency Mechanisms

- `json_blueprint`: Configured via local path dependency `path = "../json_blueprint"`. Tested against revision `d3f0708b61eddb4a4789c0476ab5384267814a51`.
- `sinal`: Configured via local path dependency `path = "../sinal"`. Tested against revision `dd09933e5466628f7d46fa896c389f31ba7d4cb6`.

---

## 9. Retained Backlog and Divergences

Full mapping documented in `DESIGN-COVERAGE.md`. Deferred capabilities:

1. Google Gemini provider adapter.
2. Multimodal inputs (audio, images).
3. Prompt caching and reasoning deltas.
4. WebSocket and bidirectional realtime transports.
5. ReqLLM FFI backend adapter spike.
6. Schema-bearing compile-time code generator with freshness proofs.

---

## 10. Safety and Boundary Confirmation

- Zero git commits created.
- Zero git remotes configured.
- Zero git push operations performed.
- Zero live provider API calls executed; zero credentials accessed or stored.
- Stopped cleanly for independent Sol Medium review.
