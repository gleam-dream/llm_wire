# `llm_wire` Wave 3 final correction review

Date: 2026-09-21  
Baseline: `e643755` plus the current staged, unstaged, and untracked recovery set  
Scope: final verification of the ordinary-JSON decision and the residual pooled-owner cleanup

## Verdict

**Accept the delivered correction subset.** No blocking finding remains in this focused review.

The provider wire boundary now uses ordinary `gleam/json` parsing and Gleam decoders. The separate strict-JSON module and Erlang FFI are absent, and duplicate-member rejection is no longer an acceptance criterion. Blueprint remains attached to the schema domain: tool schemas, structured-output schemas, and schema-backed validation and decoding.

The pool now stops the parked connection owner when the monitored Gun connection dies. The peer-close regression exercises the Gun `DOWN` path, observes removal of the dead pooled entry, and proves the pool can establish and use a replacement under one-per-target and one-total limits. Every pool shutdown in the pool suite now asserts the fallible stop result.

This is acceptance of the delivered subset, not completion of the broader Wave 3 capability scope. The updated report continues to describe that scope as partial. Strict response-header preallocation also remains unavailable with the current Gun interface and still requires the explicit contract decision already recorded: patch or pin a suitable Gun interface, or declare the capability unavailable. The contract must not be weakened silently.

## Independent evidence

### Ordinary JSON boundary

- `src/llm_wire/openai.gleam`, `anthropic.gleam`, and `google.gleam` parse provider response envelopes with `gleam/json.parse` and typed or dynamic Gleam decoders.
- Continuation argument validation in `src/llm_wire/api.gleam` uses `json.parse(raw, decode.dynamic)`. Google tool-result object recognition likewise uses `json.parse` with a Gleam dictionary decoder. Request and continuation values are emitted through `gleam/json` values and encoding, with validated raw argument objects inserted where the provider requires JSON values rather than strings.
- Neither `src/llm_wire/internal/strict_json.gleam` nor `src/llm_wire_strict_json_ffi.erl` exists in the working tree. No source or test reference to `strict_json`, `wire_json`, direct OTP `json:decode`, duplicate-member callbacks, or duplicate-member guarantees remains.
- Blueprint imports are limited to the codec/schema and runtime validation paths in `types.gleam`, `api.gleam`, and `schema.gleam`. They are not used as the generic provider wire parser.

This satisfies the authoritative simplification decision. Duplicate JSON members follow the standard parser's semantics; the package does not add a second parser or advertise a stricter wire guarantee.

### Pooled owner lifecycle

`src/llm_wire_gun_pool.erl:296-310` handles a monitored Gun connection `DOWN`. It now calls `stop_owner(Entry#conn_entry.owner_pid)` before notifying any lessee and removing the connection entry. This closes the terminal path identified in the preceding rereview: the successful connector worker waits in `keep_connection_owner/1` for exactly that stop message after transferring the connection.

`pool_remote_connection_death_reclaims_entry_test` closes the first connection from the peer, waits until the pool reports zero connections, and then completes another request through a new connection while both configured connection limits are one. The test directly exercises entry reclamation and replacement capacity. The source assertion supplies the complementary owner-exit guarantee because the parked worker's only receive clause exits on `stop`.

All nine `stop_pool(p)` calls in `test/llm_wire_pool_test.gleam` assert `Ok(Nil)`. The earlier unused-result warnings are gone.

## Verification

- `nix develop --command gleam test --target erlang`: **pass**, 122 tests, no failures and no unused-result warnings.
- `nix develop --command sh test/external_package_boundary.sh`: **pass**. The root-facade consumer compiled, and forbidden prepared-call construction, raw transport access, and `api.prepared_headers` access failed at the package boundary as expected.
- `nix develop --command gleam check --target erlang`: **pass**, no warnings.
- `nix develop --command gleam format --check src test`: **pass**.
- `nix flake check`: **pass** for the host system; Nix reported the other systems as incompatible and omitted them.
- `git diff --check` and `git diff --cached --check`: **pass**.

No `llm_wire` source or test file was changed during this review, and no commit was created.
