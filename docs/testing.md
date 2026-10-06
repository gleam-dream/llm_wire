# Testing and recording

## Local validation

- Run in the pinned Nix shell with sibling HTTP Gun, Blueprint and Sinal checkouts present. Package gates use local/offline inputs; a historical passing log is evidence for its recorded revision/runtime only.

```sh
nix develop -c sh dev/gate fast
nix develop -c sh dev/gate full
nix fmt
nix flake check
```

| Check                                       | Fast | Full        | What it establishes                                     |
| ------------------------------------------- | ---- | ----------- | ------------------------------------------------------- |
| Tree/Gleam formatting                       | yes  | yes         | Declared formatting                                     |
| Gleam check/build with warnings as errors   | yes  | clean build | Public types and compiler checks                        |
| Erlang test bridges with warnings as errors | yes  | yes         | Test FFI compilation                                    |
| Production boundary/public module-doc audit | yes  | yes         | Named forbidden paths and documentation presence        |
| Gleam and classifier Python tests           | yes  | yes         | Named semantic, local H1/TLS and server cases           |
| External positive/negative consumers        | no   | yes         | Public adoption and intended opacity errors             |
| Local nghttpd H2/concurrency harness        | no   | yes         | Finite local trust, isolation and resource observations |
| Git diff whitespace                         | yes  | yes         | Patch whitespace                                        |

- `test/external_package_boundary.sh` uses the checked-in consumer dependency closure with absolute local paths. Negative fixtures use `compile-package --no-beam` against a positive compiled control, so missing dependencies do not impersonate intended type errors.
- `dev/local-http.py` starts controlled verified-TLS/H2 fixtures. It measures finite simultaneous demand and sibling cancellation; it does not establish provider throughput, universal parser allocation or a soak guarantee.
- Raw adoption receipts remain under `docs/evidence/http-gun/`. [ADR-0002](adr/0002-http-resource-authority.md) identifies the historical runtime/source revisions and limits; [oracle guidance](../test/oracle/README.md) identifies selected upstream cases.

## Offline consumers

- [The separate consumer](../examples/consumer/README.md) exercises text, native structured output, tool rounds, streaming, custom provider, client supervision and script/cassette modes through public imports. Its classification consumer uses both TypeSafe and an independent array envelope.
- HTTP Gun owns scripts, current binary cassettes, strict playback, recording and publication. Missing, corrupt, incompatible, mismatched or exhausted playback never falls back to a network; a mismatch does not consume the expected exchange.
- Semantic `llm_wire/testing` replies lower through the real provider reducer. Raw event builders support malformed/fragmented/custom protocols; high-level final-answer substitution alone is not provider reduction evidence.
- The retry helper currently sleeps an uncapped provider delay. [ADR-0007](adr/0007-preserve-observed-contract-gaps.md) records that open example behavior; bound caller waiting before adapting it for production.

## Opt-in commercial-provider recording

- `test/cassettes/live/` contains sanitized named OpenAI, Gemini and TypeSafe responses. Normal replay is offline and credential-free. `dev/record-live` is opt-in and spends provider tokens; it is never part of `dev/gate`.

```sh
nix develop -c sh dev/record-live
nix develop -c sh dev/record-live google-tool-call
```

- The recorder's environment supplies provider credentials using its documented environment variable names. Local secret files stay ignored; credential values must not enter logs, source, telemetry or ordinary documentation.
- Inspect each recording's publication/redaction result separately from successful generation. HTTP Gun removes its documented credential metadata; arbitrary prompt bodies, queries and unlisted headers may retain sensitive content and remain the recorder owner's responsibility.
- Scenarios and request assertions are in `test/live_scenarios.gleam`, `test/classification_live_scenario.gleam` and replay tests. A cassette proves the named request/response at its recorded revision/model, not every currently offered model.

## Native design validation

- The pinned flake apps project the ignored renderer on a fresh checkout. Render the whole layer before its integrity/freshness gate; context projection is an ephemeral reader format.

```sh
nix run /code/gleam-dream/llm_wire#design-gate-render -- docs/design docs/design/design-layer.pdf
nix run /code/gleam-dream/llm_wire#design-gate-check -- docs/design .
nix run /code/gleam-dream/llm_wire#design-gate-context -- docs/design --estimate
nix run /code/gleam-dream/llm_wire#design-gate-context -- docs/design --manifest
```

- Passing the design gate establishes well-formed links, declarations and fresh rendering. Semantic conformance and remaining pending entries require source/consumer review; they are not certified by a PDF or token estimate.
