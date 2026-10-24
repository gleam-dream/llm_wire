# Keep usage as compiled examples and the oracle and benchmark references as retained docs

<a id="adr-0017"></a>

## Decision and alternatives

- Usage guidance lives as compiled, offline programs in the public consumer (`examples/consumer/src/`), one per topic, run by the full gate. The README keeps a short usage section that mirrors them, and its first Gleam block is checked against the compiled `readme_call` example by `dev/readme_example_test.py` in the fast gate. No standalone prose usage guide exists, so a guide cannot drift from the public API.
- [ORACLE.md](../ORACLE.md) and [BENCHMARKS.md](../BENCHMARKS.md) are retained documents under `docs/`. They pin the upstream implementations the tests compare against and record the finite local measurement. They cross-link, `AGENTS.md` and the README link both, and the design links them from its verification section instead of repeating their detail.
- Folding both into the design and the ADRs alone was rejected: the pins, selected cases and dated results are reference data that a reader and an agent consult directly, and the design states rules rather than inventories. Keeping a prose usage guide was rejected because nothing fails when the API changes underneath it.

## Evidence and limits

- The usage examples are `usage_defaults`, `usage_conversation`, `usage_failures`, `usage_testing`, `usage_observe` and `usage_client`, beside the existing consumer flows for structured output, tool rounds, streaming, retries, a custom provider, classification and transcription. Formatting of the examples runs in the fast gate; building and running them runs in the full gate through `test/external_package_boundary.sh`.
- The two retained documents are reference data, not design authority. A number in BENCHMARKS.md never becomes a gate threshold ([ADR-0015](0015-bound-http-benchmark-claims-to-the-local-fixture.md)), and agreement on an ORACLE.md case is not parity with the upstream suite ([ADR-0005](0005-native-reducers-and-bounded-oracles.md)).
