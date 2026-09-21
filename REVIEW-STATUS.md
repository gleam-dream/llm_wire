# LLM Wire Wave 2 correction final review

- **Baseline:** `e5b7b0b` plus the complete staged, unstaged, and untracked tree in `/code/gleam-dream/llm_wire`.
- **Scope:** focused verification of the two residual findings in `llm-wire-wave2-rereview.md`, plus the external root-facade consumer.

## Verdict

- **Accept the seven-blocker correction subset.** The raw network paths now require an opaque `api.PreparedCall`, and the schema projection now matches Blueprint's canonical nullable representation.
- **Do not mark full Wave 2 complete.** Google, connection pooling/reuse, the strict pre-allocation response-header cap, the broader process-race and provider/transport fragmentation matrix, duplicate JSON-member coverage, and complete selected-oracle inventory remain open in `WAVE-2-REPORT.md`.

## Adherence

- The transport bypass is closed without relying on module-name privacy. `api.PreparedCall` is opaque at `src/llm_wire/api.gleam:23-38`; preparation alone constructs it after provider option, schema, header, route, and request-size admission at `api.gleam:349-423`.
- Every public network path requires that opaque value. `runtime.stream` passes it to `internal/client.open_prepared_stream` (`runtime.gleam:8-14`); the client passes it to `internal/transport.connect_and_stream` (`internal/client.gleam:10-20,47-62`); the transport passes it to `api.connect_prepared_and_stream` (`internal/transport.gleam:21-51`). The final API function reads host, port, path, headers, and body only from the prepared value at `api.gleam:159-214`.
- Caller-selected TLS cannot weaken a remote request. `api.gleam:216-255` permits plaintext and a caller CA only for loopback hosts; remote hosts require `VerifySystem`. Public prepared-value accessors expose copies for inspection but provide no constructor, field update, or replacement path.
- Nullable schema parity is closed. `schema.gleam:45-60` emits Blueprint's canonical null-first `anyOf`; `llm_wire_api_test.gleam:80-110` compares every admitted recursive constructor, including nested nullable forms, with `codec.schema_value` after JSON parsing.

## Spec

- `test/external_package_boundary.sh:23-38` compiled a separate package that prepares through the root `llm_wire` facade.
- The negative dependent package at `test/external_package_boundary.sh:40-107` failed compilation when it tried to fabricate `PreparedCall`, pass a string body to the prepared client, call the removed raw client entry, or pass raw destination/header/body fields to the transport. The failures reached each intended symbol and type boundary.
- The root facade remains usable through the package-supported path. No arbitrary body, authorization header, destination, or weakened remote TLS mode crosses a public network entry.

## Standards

- No new repository-rule violation was found. This review changed no LLM Wire source and created no commit.

## Craft

- The external-package regression fixes the prior test-scope defect because its positive and negative consumers compile as dependents rather than as modules inside `llm_wire`.
- The schema regression fixes the prior single-fixture defect with a recursive constructor table and canonical structural comparison. No residual finding remains in the focused scope.

## Independent checks

- `nix develop --command sh test/external_package_boundary.sh`: passed. The external root consumer compiled; every raw-call probe failed at the prepared-call boundary.
- `nix develop --command gleam test --target erlang`: passed, 92 tests.
- `git diff --check`: passed.

## Routing

- No `(cure-class, timing)` proposal remains for the two residual findings.
- The correction subset is accepted. The separately recorded full-wave work remains tracked and was not reopened by this focused review.
