# HTTP Gun migration validation

Prepared 2026-09-30. This receipt concerns the migrated LLM Wire checkout, not
HTTP Gun's archived LLM demo or earlier donor validation matrix. Validation was
performed before the migration's local commit. No push, publication or provider
call was made.

## Inputs and runtime

- LLM Wire base: `bbde1d927675e3fe55dcbc5f456a9bcb6fe24107`.
- HTTP Gun: `ebf2b479761e8c932b0c85a8f83cf8460c014d4f`, local path dependency,
  unmodified source checkout. Gun 2.6.0 and Cowlib are released transitive packages.
- Darwin ARM64 25.5.0; Gleam 1.18.1; OTP 28.5.0.6 / ERTS 16.4.0.6;
  rebar3 3.27.0; nghttpd/nghttp2 1.70.0. Exact output: [runtime.json](evidence/http-gun/runtime.json).
- Nix pins remain in `flake.lock`; dev shell adds Python, nghttpd, ripgrep and
  the pinned treefmt wrapper. `gleam.toml` and `manifest.toml` add local HTTP Gun;
  only LLM Wire's dependency/tooling files change.
- [sources.json](evidence/http-gun/sources.json) identifies source inputs and
  sibling state. [Donor provenance](evidence/http-gun/donor-source.json) records
  hashes and Apache-2.0 attribution before reusing validation patterns.

## Exact validation

Final outcomes: **fast and full profiles passed, 223 tests, no failures**.
The full profile started from clean build output. Logs:
[fast-gate.log](evidence/http-gun/fast-gate.log) and
[full-gate.log](evidence/http-gun/full-gate.log). The gate commands
are `nix develop -c sh dev/gate fast` and `nix develop -c sh dev/gate full`;
[gate-manifest.md](implementation/http-gun/gate-manifest.md) maps each obligation
to its check. Individual retained observations:

- Baseline `nix develop -c gleam test`: 208 passed.
- Migrated `nix develop -c gleam test`: 223 passed after semantic, fixture,
  exception-cleanup, TLS setup cancellation, ordered concurrent recording and
  race fixes; [recording-order.log](evidence/http-gun/recording-order.log).
- `nix develop -c sh test/external_package_boundary.sh`: positive external
  provider/schema/history/telemetry consumer compiles and the separate actual
  checkout consumer executes scripts and offline playback. Negative constructors,
  raw `Request(BitArray)`, stored credential fields, continuation/checkpoint and
  old pool APIs fail for their intended type/value/field reasons, not missing
  dependencies. The full gate repeats these probes.
- `nix develop -c python3 dev/local-http.py`: independent verified TLS/H2,
  sibling cancellation and barrier-released concurrency; [local-http.json](evidence/http-gun/local-http.json).
- `nix fmt`: pinned Gleam/Nix/Markdown/JSON formatting.
- `nix flake check`: host formatting derivation passes. Its incompatible-system
  notice is not another OS/OTP validation claim.

The full profile cleans build output, checks/builds, treats LLM build warnings
as errors, compiles both test Erlang bridges with `erlc -Werror
+warn_unused_vars +warn_unused_function`, runs all tests, external consumers and
nghttpd. Earlier reruns hit Hex rate limits because temporary consumer packages were
resolving dependencies afresh (`full-gate-hex-failure.log`). The boundary gate now
seeds temporary consumers from the actual consumer manifest, preserving locked
versions. A successful compile alone did not eliminate registry access on failed
checks. Negative probes now use Gleam's supported `compile-package --no-beam`
build-tool API against the positive consumer's compiled dependency closure;
a valid control compile verifies that closure before the intentional errors.
Positive consumers still use ordinary `gleam check` and `gleam run`.
Fresh dependency
builds emit existing deprecation warnings in
`anthropic_gleam`, `gramps` and `mist`; no dependency was patched. One formatter run rejected a concurrently updated evidence file
(`full-gate-input-change.log`); final validation used stable, formatted inputs.
Expected TLS
rejection and controlled reducer-exception logs are part of passing tests.

## Preserved and added observations

| Area                                                                                                                         | Evidence                                                                                                                                                                                                                                               |
| ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Pure opaque preparation and same buffered/streamed execution                                                                 | session, API and external consumer suites; `session.run` collects the same semantic stream                                                                                                                                                             |
| Built-ins, custom provider, tools, structured output, signed Google assistant/tool rounds                                    | retained provider, session, integration, turn, tool-call-check, custom-provider and selected oracle suites, migrated to HTTP Gun                                                                                                                       |
| Multimodal/cache, usage/refusal/output-limit, schema/native admission and telemetry                                          | retained API, provider, tool-call-check, session and oracle suites; no expansion of previously unsupported profiles                                                                                                                                    |
| SSE/body/progress/metadata bounds and fragmentation                                                                          | retained SSE/owner suites plus all three built-ins through byte-at-a-time HTTP chunks with split UTF-8 and CRLF; every two-chunk split remains tested                                                                                                  |
| Admission/connection/headers/body cancellation, fixed deadline, independent read/idle, slow readers and owner/consumer death | shared-client and adapter suites; stalled TLS handshake probe; existing copied-handle/conflicting-read tests                                                                                                                                           |
| Early provider terminal before HTTP EOF                                                                                      | synchronized H1 server never sends the final HTTP chunk; semantic result returns and peer observes close                                                                                                                                               |
| Typed conservative evidence                                                                                                  | request-byte pre-submission rejection, stopped-client ambiguity, raw/semantic partial responses, status-body idle race, cancellation and terminal races                                                                                                |
| One fixture system                                                                                                           | current binary disk schema, duplicate replies, non-consuming mismatches, significant headers, synchronized reverse-completion recording with admission-ordered replay, missing/corrupt/incompatible/exhausted/bounded fixtures and no network fallback |
| Actual recording and persistence separation                                                                                  | local server observes text, tool/result and structured calls; server is stopped before replay; early cancellation, capture limit, destination refusal and publication IO failure are separate from successful live semantics                           |
| H1 reuse, trust and H2 isolation                                                                                             | shared H1 socket tests, verified custom CA, hostname/untrusted-CA rejection and independent nghttpd ALPN H2 with two resets and one healthy 2 MiB sibling                                                                                              |

Failing regression witnesses are retained: `read-terminal-race-red.log`,
`close-race-red.log` (50 simultaneous closes), and `status-evidence-red.log`
(partial status bytes before idle expiry). These were corrected, not erased.
Four obsolete/moved scenarios explain the temporary 221-to-217 cutover count:
two obsolete per-call CA policy tests were removed; ten old pool implementation
tests became eight shared-client scenarios, with cancellation/death coverage in
the new adapter suite. Later regressions add coverage; provider semantics were
not deleted to make migration tests pass.

## Practical concurrency

The local harness uses one verified H2 connection, peer stream limit 8, client
active/waiting limits 2048 each and a 120-second ceiling. All N caller processes
exist behind a barrier before any request is released. This is simultaneous
application demand, not a bounded batch of sequential workers; HTTP admission
still limits actual in-flight streams. One 2 MiB response remains stalled during
small-response load. The receipt's `slow_stream_bytes` counts text; SSE framing
adds overhead. Separately, cancellation of one 2 MiB stream preserves a
healthy sibling that collects all 2 MiB. nghttpd observes 1116 requests and two
RST_STREAMs on one request-bearing connection. The extra readiness TCP probe
never carries an HTTP request.

| Simultaneous callers | Failures | p50 ms | p95 ms  | Max ms  | VM peak MiB | Largest process MiB | Max single mailbox |
| -------------------- | -------- | ------ | ------- | ------- | ----------- | ------------------- | ------------------ |
| 1                    | 0        | 0.811  | 0.811   | 0.811   | 59.73       | 1.72                | 1                  |
| 10                   | 0        | 1.145  | 1.294   | 1.328   | 58.08       | 1.72                | 1                  |
| 100                  | 0        | 9.284  | 14.491  | 14.693  | 61.77       | 1.72                | 2                  |
| 1000                 | 0        | 79.604 | 140.764 | 150.614 | 97.35       | 7.49                | 873                |

| Callers | Sampled processes | Total sampled mailbox peak | HTTP connections | VM ports |
| ------- | ----------------- | -------------------------- | ---------------- | -------- |
| 1       | 98                | 1                          | 1                | 3        |
| 10      | 106               | 2                          | 1                | 3        |
| 100     | 198               | 2                          | 1                | 3        |
| 1000    | 3785              | 873                        | 1                | 3        |

Resource measurements sample the whole Erlang VM every 10 ms; small runs can
finish between samples. Max process memory is the largest sampled process, not
an assertion about one semantic owner. VM ports are reported separately from the
single server-observed socket. The log retains a bounded 256 KiB prefix and a
hash of all observed server output. This is a finite local workload, not a soak,
provider throughput promise or protocol-parser memory certification.

## Removal, ownership and remaining limits

There is one production HTTP execution adapter:
`session` → `internal/http_client` → documented HTTP Gun consumer API. The
existing semantic owner/reducers remain; one linked Gleam worker reads its own
body with one credit. No direct production Gun import, custom pool, old connector,
HTTP cassette codec, eager forwarding loop or hidden per-call client remains.

The two primary deleted transport FFIs total **1057 physical lines**; the old
cassette FFI is also removed. Production handwritten Erlang is **zero**. Tests
retain the 61-line TCP bridge and a 13-line VM snapshot/clock bridge: **74 lines**,
with no orchestration server. HTTP deadlines use HTTP Gun's public clock API.

Only this Darwin ARM64 OTP 28 execution is validated. Linux, OTP 27/29,
provider endpoints, exhaustive provider conformance and long-running soak were
not run. HTTP Gun's previous matrix is not reused as LLM evidence. Fabric and
overview design integration remain separate tasks. Body/query redaction,
crash/power-loss durable publication and dependency parser hardening are optional
or excluded work, not missing migration contracts. The package still uses local
unreleased dependencies; registry publication and hosted CI remain release work.

The exact wire-submission timestamp is not exposed by the HTTP Gun consumer API.
The retained `request_sent` telemetry stage is therefore emitted at the response
head with outcome `http_response_started`; applications measure end-to-end time
around execution. This observation timing change is documented explicitly.

The focused migration has no identified public-API blocker. This implementation
report does not substitute for the separately requested independent adoption
review (Prompt 2).

HTTP Gun remains clean at the reference revision. Oversight retains its initial
untracked `.claude/`. Fabric developed concurrent changes under
`experiments/writing_authoring/` and `scripts/check.py`; those were not written or
reverted by this migration. Thus a claim that every sibling's Git status stayed
identical would be incorrect. No sibling source files were changed by this work.
