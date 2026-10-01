# HTTP Gun migration wave tracker

- Updated: 2026-09-30. Status: complete; all five waves validated.
- Authority: user's Prompt 1 in this conversation approves all five waves and the HTTP Gun adoption. No further design approval is required for this scope.
- Target: one opaque prepared provider request → shared HTTP Gun client → bounded SSE semantic owner → caller-owned response/turn.
- Baselines: LLM Wire bbde1d927675e3fe55dcbc5f456a9bcb6fe24107; HTTP Gun ebf2b479761e8c932b0c85a8f83cf8460c014d4f. Both clean. Oversight has untracked .claude/; Fabric has untracked experiments/writing_authoring/. Preserve siblings.
- Baseline gate: `nix develop -c gleam test`: 208 passed, no failures. Sandbox required Nix daemon access.
- Design authority: caller-owned-conversation.md plus Prompt 1; older continuation/checkpoint and dependency-hardening proposals are superseded.
- Substitution during waves 1–4: old transport remains only while existing tests are moved; remove all production direct Gun/pool/fixture code in wave 5.
- Current: 223 tests pass, one production HTTP path remains, and the external consumer plus local TLS/H2/concurrency checks have passed. The fast and full gates pass on the final source.

## Approved wave map (revision 1)

| Wave | Observable outcome and state contract                                                | Boundary / adoption                                                              | Scenarios and exit evidence                                                                                                  |
| ---- | ------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| 1    | Pure prepare, execution opens one fixed-budget request, same semantic collection     | Add local HTTP Gun; standard Request(BitArray) created internally                | Baseline, red/green local public buffered call, build/test                                                                   |
| 2    | Open → progress → terminal or local cancellation; one read credit, one body consumer | Gleam worker holds cancellation scope for session lifetime; HTTP Gun owns HTTP   | Pre-header cancel, idle vs read vs deadline, owner death, copied handles/conflicts, early terminal, typed monotonic evidence |
| 3    | All existing provider/tool/structured/caller-owned behavior                          | Existing reducers, admission and telemetry retained                              | Built-ins/custom, signed Google turns, multimodal/cache, fragmentation and bounded queues                                    |
| 4    | Same session with scripts, strict disk playback and actual live recording            | HTTP Gun alone owns fixtures and capture; retain pure LLM reply builders         | Ordered duplicate/mismatch, text/tool/structured round trips, cancellation, capture/persistence failures                     |
| 5    | Ordinary external adoption; one production HTTP path                                 | Remove old transport/pool/cassette; update toolchain, consumers and local design | Fast/full gates, external opacity, H1/TLS/H2 sibling isolation, 1/10/100/1000 load, unchanged siblings                       |

Each wave uses one failing observable scenario followed by implementation and focused verification. Full exit checks cover formatting, check/build, FFI warnings, tests and external consumers; full local validation additionally covers controlled TLS/H2 and concurrency. Only OTP 28 is claimed until independently measured. Implementation waves used no commits, provider endpoints, credentials, dependency patches or sibling edits. The user subsequently authorized a local commit of the completed migration.

## Adapter invariants resolved before implementation

- The semantic owner starts a linked Gleam worker. Only that worker opens and reads the HTTP body. It waits for one `More` credit before each chunk; no response-byte queue or eager forwarding loop is added.
- The worker's `cancellation.with_token` callback encompasses opening, all reads and close. The semantic owner's transport close latches that token. Abnormal owner death ends the linked worker; HTTP Gun observes worker death. Normal owner shutdown calls cleanup. HTTP and token scopes close on exceptions.
- Create a deadline once at execution. Owner timer uses its remaining budget; HTTP Gun gets that same absolute value. Zero stays expired. Semantic idle resets only on progress. Consumer read timeout cancels only the pending semantic read. HTTP read-wait timeout retains the worker's outstanding credit.
- Failure classification uses HTTP Gun variants, never diagnostic parsing. NotSubmitted → NoRequestSent; MayHaveBeenSent → RequestMayHaveReachedProvider. OR independently observed bytes/progress with reducer evidence, with EffectUnknown dominant. Local close never proves provider cancellation.
- HTTP status, finite error-body reads, Retry-After, encoding/type checks remain LLM policy. Provider terminal closes immediately; no draining.
- Client lifetime and trust are application-owned. Document a client deadline ceiling at least the longest LLM budget (HTTP Gun defaults to 30s; LLM Wire defaults to 60s). Remove old CA/pool/idle-eviction options at cutover.

## Provenance

No donor source copied initially. HTTP Gun signatures verified in the baseline public modules and README/BOUNDS/API_ERGONOMICS/DESIGN/ADOPTION_VALIDATION and ordinary/LLM examples. Existing local wave reports are historical receipts, not migration evidence. Record hashes before any later donor reuse.

## Wave 1 — local prepared buffered request

Accepted 2026-09-30. `nix develop -c gleam test`: 209 passed, no failures (`docs/evidence/http-gun/wave1-green.log`). Red: missing HTTP Gun dependency/public execution entry (`wave1-red.log`); first runtime attempt exposed required lowercase standard HTTP header names, corrected internally; fixture correction added the required OpenAI item completion. Local request runs through HTTP Gun, worker, existing owner, SSE and reducer. No donor source copied. Old entry points remain temporarily for test migration. Next: lifecycle and evidence.

## Wave 2 — worker lifecycle and evidence

Accepted core slice 2026-09-30. `nix develop -c gleam test`: 217 passed, no failures (`wave2-green.log`). Added typed `HttpFailure(Reason)`, preserved HTTP evidence (including conservative closed-client MayHaveBeenSent), fixed absolute budget passed into owner startup, pre-header close, consumer death during opening, read-timeout preservation, semantic idle under keepalives, execution-time budget after delayed preparation, provider terminal before HTTP EOF and partial raw/semantic evidence. Existing copied-handle/conflict/queue owner tests remain. Shared H2 and wider stress proof remain wave 5 acceptance work. One linked Gleam worker and HTTP Gun's scope; no new handwritten FFI. Next: built-in/custom and structured/tool workflows, then fixture consolidation.

## Waves 3–4 — semantic preservation and one fixture contract

Closed core slices 2026-09-30. `nix develop -c gleam test`: 221 passed before obsolete-path cutover; `wave4-recording.log`. Google, custom-provider, structured, signed-turn and tool-admission tests now use the HTTP Gun path. Scripts retain only pure reply builders and lower opaque prepared calls into sanitised HTTP Gun exchanges. No request-history process is retained. Current binary schema, repeated sequential exchanges, non-consuming mismatches, header matching, strict missing/corrupt/version/exhaustion and partial evidence are exercised. Actual local HTTP recording/replay uses text, tool/result rounds and structured output; capture budget and explicit destination replacement are separate outcomes. `finish_wait` does not drain an unfinished semantic stream; local cancellation replays with observed bytes/progress. The owned fixed disk fixture was regenerated explicitly. Earlier experimental HTTP JSON fixtures were removed, not archives.

## Wave 5 cutover and final validation

The old production pool, Gun transport FFI, connector, and cassette codec are removed. TCP infrastructure moved intact to test/. Production handwritten FFI is currently zero. Core cutover test run: 217 passed, no failures; four obsolete/moved scenarios explain count change (two removed CA-per-call policy tests; ten pool implementation tests consolidated to eight shared-client scenarios, with pre-header owner death and cancellation covered in the new adapter suite). A read/deadline race was reproduced (`read-terminal-race-red.log`) and fixed by monitoring owner exit while settling pending reads. These remaining checks were completed below; retain this cutover receipt as the intermediate checkpoint.

## Final regression evidence

`close-race-red.log` reproduces `ReadTimeout` from simultaneous copied-handle
closes. Owner-exit monitoring makes all fifty closes idempotent.
`status-evidence-red.log` reproduces lost response-byte evidence when semantic
idle wins during an unfinished HTTP status body. A first-byte notification
preserves that evidence independently of eventual collection. The corrected
suite passes 221 tests in `status-evidence-green.log`, including publication IO
failure, reducer-exception cleanup and byte-at-a-time UTF-8/CRLF provider paths.

Local nghttpd has negotiated H2 over verified custom-CA TLS, observed two
RST_STREAMs and 1116 requests on one connection, preserved a healthy 2 MiB
sibling and served barrier-released 1/10/100/1000 callers with zero failures
while a second long stream was stalled. These are finite local observations;
see the final validation report, not an inferred universal memory guarantee.

The last two scenarios cover cancellation during a stalled TLS handshake and
concurrent recording with explicitly ordered admission but reversed completion.
All 223 tests pass (`recording-order.log`). The TLS probe was corrected to allow
shutdown alerts before EOF; no dependency change was required. Temporary
external consumers now inherit the verified version lock; a preserved Hex rate
limit failure explains that gate adjustment (`full-gate-hex-failure.log`).

## Final exit

`nix develop -c sh dev/gate fast` and `nix develop -c sh dev/gate full` both pass;
223 tests, actual external positive consumers, six intended negative boundaries,
verified H1/TLS/H2, real recording/replay and 1/10/100/1000 simultaneous callers.
The full gate uses Gleam's documented `compile-package --no-beam` API for negative
probes against the positive consumer's compiled closure, eliminating repeated
registry resolution on expected failures. A priming compile alone was insufficient.
`nix fmt`, `nix flake check`, the source-path audit and patch whitespace checks pass.
The exact runtime, sampled measurements, final source hashes, removed FFI and
remaining OS/provider/release limits are in `docs/http-gun-validation.md`.
HTTP Gun stays clean at its baseline; Oversight retains its initial untracked
folder. Fabric changed concurrently; its changes were neither made nor reverted
here. There were no sibling writes, commits, pushes, provider calls or publication.
