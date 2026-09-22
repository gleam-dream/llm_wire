# LLM Wire Wave 3 report

## Outcome

The interrupted Wave 3 tree was continued from baseline e643755. Its staged, unstaged, and untracked work was retained; no reset, commit, push, publication, live provider request, or real credential use occurred.

The requested implementation slice is present and has a green local package suite: Google GenerateContent text/tool interaction, ordinary Gleam JSON parsing and decoding, explicit optional Gun connection leases/reuse, bounded pool waiters and shutdown, representative provider fragmentation, and continuation/cleanup cases. The strict response-header allocation contract remains a concrete transport decision, and declared Wave 3 capability families remain unfinished. This is partial delivery, not Wave 3 acceptance or release readiness. DESIGN-COVERAGE.md carries the row-by-row capability state; independent Sol Medium review remains with the coordinating task.

The interrupted agy process ended with quota exit 75 while a background boundary-test process was still pending and provided no final report. I did not trust that result. I reran the dependent-package boundary probe synchronously to completion; it passed. The changed tree remained in place and was not reset.

## Public API example

A consumer can prepare a request through the root facade, then choose a direct one-request connection or an explicit reusable pool:

    import json/blueprint/codec
    import llm_wire

    let assert Ok(key) = llm_wire.api_key("caller-supplied")
    let assert Ok(endpoint) = llm_wire.endpoint("https://api.openai.com/v1")
    let assert Ok(model) = llm_wire.model_id("model-name")
    let config = llm_wire.openai_config(key, endpoint, None, None)
    let assert Ok(name) = llm_wire.tool_name("lookup")
    let assert Ok(tool) = llm_wire.tool_from_codec(
      name,
      "Look up one item",
      codec.field("id", codec.string()),
    )
    let request =
      llm_wire.new_request(model, [llm_wire.UserMessage("find item")])
      |> llm_wire.with_tools([tool])
    let assert Ok(prepared) =
      llm_wire.prepare(config, request, llm_wire.default_limits())

    let assert Ok(pool) =
      llm_wire.start_pool(llm_wire.default_pool_config())
    let result = llm_wire.run_with_pool(
      pool,
      prepared,
      llm_wire.default_limits(),
      llm_wire.default_deadlines(),
    )
    llm_wire.stop_pool(pool)

The common API also exposes stream, next, close, structured-output preparation, and prepare_continue. The prepared interaction remains opaque. Internal client and transport entry points accept only PreparedCall, and the external-package probe checks that a consumer can use the facade but cannot fabricate PreparedCall or send raw bodies/routes through those seams.

## Previous review findings and Wave 2 gaps

The Wave 2 final review accepted the correction subset but did not accept the full wave. Its seven blockers remain closed by the existing source and regression evidence:

- Blueprint's transmitted schema projection matches the canonical recursive Blueprint projection, including null-first nullable branches.
- Tool calls remain terminal-only; no individual closed block is exposed as executable work.
- Opaque continuation remains bound to its originating prepared interaction and exact result IDs.
- Public transport use requires opaque PreparedCall; a real dependent-package negative probe checks constructor and raw-client/transport misuse.
- Named provider refusal, cancellation, unknown-stop, and hosted-effect outcomes remain distinct.
- Read-timeout acknowledgement preserves progress accepted at the timeout boundary.
- The root facade supports consumer construction without importing the implementation types module.
- Credential-bearing prepared headers are private; the external dependent-package probe now attempts the removed accessor and requires that diagnostic.

The specific open Wave 2 items now have these outcomes:

| Open item                                   | Wave 3 disposition                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Google adapter                              | Implemented for the documented text/tool/usage/strict-schema/terminal subset with local loopback fixtures. Google function declarations use the official `parametersJsonSchema` field and provider-specific Blueprint admission; stopSequences is admitted only through five values. Provider IDs are optional and omitted on continuation when Gemini omitted them. A signed Google part with thoughtSignature returns an explicit protocol error because the current neutral continuation cannot retain that opaque provider state. Broader Google model/content parity remains open. |
| Connection reuse                            | Implemented as an explicit pool path through llm_wire.start_pool, stream_with_pool, and run_with_pool. Healthy Gun connections are leased and reused; setup runs in monitored workers, Gun ownership survives worker setup, and stop returns an explicit result instead of swallowing timeout/failure. Pool and waiter resources are bounded, and per-stream close does not cancel a different lease. The default no-pool API still creates one connection per request.                                                                                                                 |
| Strict response-header pre-allocation limit | Investigated and not satisfied. Gun 2.6.0's complete-terminator path calls handle_head with the accumulated block; Cowlib parses headers before the adapter sees parsed header values. The 17 KB fixture proves rejection after parsing, not a 16 KiB allocation bound. No second parser was added. The concrete remaining decision is to take an upstream pre-parse fix or select a transport with that guarantee.                                                                                                                                                                     |
| Process/race matrix                         | Expanded with owner argument-disconnect, bounded consumer-death polling, read-timeout delivery arbitration, queue-cap and shutdown tests, pool owner-death reclamation, concurrent stream isolation, waiter timeout/FIFO, and complete provider-fragment splits. Kill-at-every-state, mailbox/process soak, and exhaustive close/death/deadline combinations remain Wave 5 release work.                                                                                                                                                                                                |
| Ordinary JSON boundary                      | Implemented with the standard Gleam JSON parser and decoders for provider envelopes, requests, responses, and continuations. Duplicate-member rejection is not a package contract. Blueprint remains reserved for schema-bearing contracts and validation.                                                                                                                                                                                                                                                                                                                              |
| Provider and transport fragmentation        | Every two-chunk byte split of complete representative OpenAI, Anthropic, and Google text interactions is fed through SSE framing and provider reduction. This is a deterministic selected corpus, not fuzzing or all-event permutation.                                                                                                                                                                                                                                                                                                                                                 |
| Selected oracle inventory                   | Updated in test/oracle/README.md with pinned ReqLLM source identity and license, exact selected case titles, local mappings, the unsupported retry policy comparison, and capability exclusions. The upstream suite was not run.                                                                                                                                                                                                                                                                                                                                                        |

## Provider and dependency evidence

ReqLLM v1.24.0 is pinned in the oracle ledger by annotated tag object 29f855513c327ec5630a16215531ad2d459ae56e and tagged commit fd9e079fddf253e9b719b2d2c6920f4306592809; its license is Apache-2.0. Jido AI v2.3.0 is contextual only because its lockfile references ReqLLM 1.17.1. Neither upstream test suite was run.

Google request and reducer behavior was checked against the official Generate Content, function-calling, structured-output, Gemini 3, and thought-signature documentation linked from test/oracle/README.md. The decoder/encoder uses the OTP standard JSON interface. The resolved local transport is Gun 2.6.0 with Cowlib 2.20.0; package license notices are retained in their dependency trees. anthropic_gleam 0.1.1 is MIT-licensed and remains dev-only: its published streaming state retains every event fed to it and its decoder filters malformed events instead of returning the strict failure needed by the owner contract.

No real provider or credentials were used. Fixtures use loopback HTTP/TLS only.

## Remaining capability rows

The complete ledger is in DESIGN-COVERAGE.md. The important remaining rows are:

| Capability                                                                                                                                                   | State and owner/wave                                                                                                                                                                         |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Strict response-header allocation bound                                                                                                                      | Decision required from LLM Wire maintainers before Wave 5 release acceptance: adopt an upstream full-block-before-parse limit or choose a transport documenting that property.               |
| Multimodal messages, embeddings, prompt caching, broad provider-specific option admission, automatic retry policy, and broader usage/reasoning/stop coverage | Wave 3 remainder owned by LLM Wire. Current requests are text-only; no embeddings or cache-control API exists. There is no automatic replay. Google thoughtSignature is rejected explicitly. |
| Persistable provider continuation, realtime/WebSocket, batch/background operations, remote cancellation acknowledgement, broader Sinal observations          | Deferred to LLM Wire Wave 4.                                                                                                                                                                 |
| Exhaustive provider differential cases, malformed-input corpus, fuzz/soak/leak and kill-at-every-state tests, OTP 27–28 runs, final packaging/API audit      | Deferred to LLM Wire Wave 5.                                                                                                                                                                 |

The current boundary and work-order do not authorize silently declaring those rows complete. Review should keep the overall Wave 3 status partial until its retained rows are resolved or explicitly re-scoped by the design owner.

## Verification

All package checks below were run synchronously and awaited to process exit:

- nix develop --command gleam format --check src test — pass.
- nix develop --command gleam check --target erlang — pass.
- nix develop --command gleam build --target erlang — pass.
- nix develop --command gleam test --target erlang — 122 passed, no failures.
- nix develop --command sh test/external_package_boundary.sh — pass; positive root-facade consumer compiled, raw-call consumer failed at the intended prepared-call boundary.
- nix flake check — pass on aarch64-darwin; Nix explicitly skipped aarch64-linux, x86_64-darwin, and x86_64-linux.
- git diff --check — pass for the working-tree diff.
- git diff --cached --check — pass. The working-tree `git diff --check` and cached check both produce no diagnostics; no interrupted changes were restaged.
- Process audit found no active llm_wire test/build command. Remaining matches were agent-lsp/gleam LSP processes; no process was killed.

The test run emits expected TLS alert/supervisor notices from negative hostname and untrusted-CA fixtures; the suite exits successfully.

## Friction and changes

Applied during this recovery:

- Removed the separate strict JSON abstraction and FFI. Provider envelopes, requests, responses, and continuation arguments now use the standard Gleam JSON parser and decoders. Blueprint remains limited to schema-bearing contracts and validation; no duplicate-member rejection guarantee is claimed.
- Removed the public prepared_headers credential accessor and added a negative external-package regression.
- Added the Google-specific parametersJsonSchema projection, optional provider-ID tracking, missing-ID continuation coverage, and the official five-value stopSequences admission limit.
- Added a hard bound to the pool waiter list and exercised invalid limits, FIFO wake-up, active-lease shutdown, and isolated stream close.
- Stopped the parked Gun connection owner on remote Gun monitor death, added remote-connection cleanup coverage, and asserted every fallible pool stop in the pool suite.
- Added an explicit Google failure for thoughtSignature so required continuation state cannot be silently lost.
- Extended byte-boundary coverage from representative SSE frames to complete provider interactions and added a tool-argument disconnect case.
- Fixed an owner-death test race by polling boundedly for the monitored process exit after cleanup notification.
- Formatted the interrupted Gleam source/test tree and new documentation; both Gleam formatting and Nix treefmt checks now pass.

Proposed, not applied:

- Patch Gun/Cowlib at an upstream seam or select another maintained transport that checks complete headers before parsing/allocation. A local second HTTP parser was explicitly excluded.
- Add a provider-state envelope before accepting Gemini thought signatures or other continuation state that cannot be expressed in the current neutral types.
- Complete the remaining Wave 3 option/content/embedding/cache/retry matrix, then add Wave 5 fuzz, soak, leak, multi-OTP, and release evidence.

No commit or integration was made. The coordinating task should obtain the independent Sol Medium review; this report does not self-accept the implementation.
