# LLM Wire Wave 3 Progress

Status: requested implementation slices and synchronous package gates are complete for this recovery milestone. The overall wave remains partial: strict response-header allocation needs a transport decision; multimodal, embeddings, caching, full provider-option/retry/reasoning coverage remain Wave 3 work; independent Sol Medium review is pending.

The checkout started at baseline e643755 with staged, unstaged, and untracked interrupted Wave 3 work. The work was preserved without reset or commit. Formatting and documentation updates remain visible as unstaged changes alongside the original staged changes.

## Milestones

1. **Baseline and recovery — complete**
   - Gleam check passed on the recovered tree.
   - The first synchronous suite had 112 passes and one failure in the connection-owner-death pool test. The fixture had sent Connection: close and exited, closing its socket before asserting the lease. It now holds the response open and polls boundedly for owner death plus lease reclamation.

2. **Google adapter and ordinary JSON — implemented for the admitted text/tool subset**
   - Google GenerateContent request/streaming, text and tool-call reduction, schema admission, usage, terminal reasons, refusals, continuation tool responses, and deterministic loopback calls are covered by test/llm_wire_google_test.gleam.
   - Ordinary provider envelopes, requests, responses, and continuations use the standard Gleam JSON parser and decoders. Blueprint remains on schema-bearing contracts and validation; duplicate-member rejection is not a package contract.
   - Google function declarations use `parametersJsonSchema`; optional provider IDs stay separate from application call IDs, and missing IDs are omitted from continuation fields. Google stopSequences admission is bounded at five values.
   - Gemini thoughtSignature cannot cross the current provider-neutral ToolCall/Continuation model. The adapter fails explicitly on a signed part; a durable provider-state envelope remains Wave 4 work.

3. **Gun lease/reuse manager — implemented and tested**
   - The optional pool reuses healthy Gun connections, keys leases by target and TLS identity, performs Gun setup in monitored workers without blocking the pool GenServer, monitors bridge owners and Gun processes, reclaims abandoned connections, checks out queued work by deadline, prunes idle connections, and closes active leases/waiters on shutdown. Stop returns explicit errors.
   - Per-target and total connection caps are validated as positive; waiter count is capped at max_total_connections.
   - Deterministic tests cover sequential reuse, concurrent stream isolation, lease owner death/reclamation, waiter timeout/FIFO check-in, queue cap, active shutdown, and invalid limits.

4. **Gun complete-header pre-allocation requirement — concrete upstream limitation recorded**
   - test/llm_wire_integration_test.gleam sends a complete 17 KB response header section in one tcp.send call and observes rejection.
   - Gun 2.6.0 gun_http.erl routes a receive containing the terminator to handle_head before max_header_block_size is checked. handle_head then calls Cowlib cow_http:parse_headers before the parsed-header count check. LLM Wire's byte check runs after Gun sends parsed headers.
   - The adapter rejects oversized headers after parsing; this is not a strict pre-allocation bound. No second HTTP parser was added. A decision is needed: adopt an upstream full-block pre-parse check or choose a transport that documents the guarantee.

5. **Adversarial provider/transport matrix — selected cases complete**
   - test/llm_wire_provider_fragmentation_test.gleam feeds every byte boundary of complete OpenAI, Anthropic, and Google text interactions through SSE framing and provider reducers.
   - Provider reducer tests cover malformed payloads without claiming duplicate-member rejection. The owner suite covers a transport error during partial Anthropic tool JSON and asserts no incomplete executable call. Other cases cover hosted-effect ambiguity, consumer death, read-timeout delivery arbitration, queue limits, setup/deadline failures, peer disconnect, and TLS rejection.
   - The full provider-option permutation, kill-at-every-state coverage, mailbox/process soak, and malformed-provider corpus remain Wave 5 hardening.

6. **Selected oracle inventory and report — complete**
   - test/oracle/README.md and WAVE-3-REPORT.md record the ReqLLM pin/license, exact selected case titles, local mappings, explicit exclusions, Google primary sources, and the fact that no upstream suite was run.

7. **Synchronous verification — complete; independent review remains**
   - nix develop --command gleam format --check src test: passed.
   - nix develop --command gleam check --target erlang: passed.
   - nix develop --command gleam build --target erlang: passed.
   - nix develop --command gleam test --target erlang: 122 passed, no failures.
   - nix develop --command sh test/external_package_boundary.sh: passed; facade consumer compiled and raw-call consumer failed at the prepared-call boundary.
   - nix flake check: passed on aarch64-darwin; other configured systems were not checked by this local flake output.
   - Working-tree and cached `git diff --check` both pass with no diagnostics; no interrupted changes were restaged.
   - Process audit found no active LLM Wire test/build command. Remaining matches were agent-lsp/gleam LSP processes; none was killed.
   - Leave independent Sol Medium review to the coordinating task. This progress record does not accept the overall wave or claim release readiness.
