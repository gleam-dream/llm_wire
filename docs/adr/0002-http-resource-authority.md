# Delegate generic HTTP resources to HTTP Gun

<a id="adr-0002"></a>

## Decision and alternatives

- The accepted 2026-09-30 migration uses one application-owned HTTP Gun client. LLM Wire retains provider admission, encoding, SSE reduction, semantic limits and conservative evidence; HTTP Gun owns generic HTTP/TLS, pooling, body resources, cancellation and fixtures.
- Keeping the donor Gun FFI, local pool or cassette engine would retain duplicate resource authorities. Adding another body server or eager byte forwarder would weaken ownership and finite-credit buffering, so one linked Gleam worker opens and consumes the HTTP response inside its cancellation scope.
- A response-head observation cannot establish the exact wire-submission time. The retained RequestSent stage explicitly means http_response_started; local close establishes neither remote cancellation nor rollback.
- The whole-call budget replaces the HTTP request timeout, and generation lifts HTTP idle while keeping its own first-progress/idle rules. Connect/pool/trust/destination constraints remain at the HTTP boundary; plaintext's concrete destination setup and HTTP Gun's intersecting view rules must be read together.

## Evidence and limits

- [1c0ad61](https://github.com/gleam-dream/llm_wire/commit/1c0ad614149b6ba286a6f778e223bd294f403b30) records extraction to shared clients; [576482e](https://github.com/gleam-dream/llm_wire/commit/576482e7b15ee877916c503c01d5de7326ef03db) records timeout-view migration. The [original contract](https://github.com/gleam-dream/llm_wire/blob/4726271d1671f48fe63222bc2133af1aacfe60e9/docs/http-gun-migration.md) and [validation report](https://github.com/gleam-dream/llm_wire/blob/4726271d1671f48fe63222bc2133af1aacfe60e9/docs/http-gun-validation.md) preserve detailed history.
- Raw receipts remain in `docs/evidence/http-gun/`, including source/runtime hashes, red/green races, recording and local HTTP measurements. The observed Darwin ARM64 OTP 28 workload reached 1,000 simultaneous callers with zero failures on a verified H2 connection; it is finite local evidence, not provider throughput, soak or universal memory certification.
- Gun 2.6.0/Cowlib's complete-header parse path was observed to allocate before the donor's post-parse header rejection. Package limits do not prove strict upstream pre-allocation bounds; dependency hardening remains explicit verification work. No undocumented transport replacement or universal allocation claim follows from the migration.
- This record consolidates HTTP migration/validation prose and the implementation tracker. Operational commands survive in [testing guidance](../testing.md); immutable source links retain the original measurement tables.
