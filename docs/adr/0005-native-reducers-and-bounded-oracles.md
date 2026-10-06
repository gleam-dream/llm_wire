# Keep narrow native reducers and scoped oracle evidence

<a id="adr-0005"></a>

## Decision and alternatives

- A public sans-I/O reuse experiment against anthropic_gleam 0.1.1 found a viable request builder but a stream state that retained fed events and a decoder that filtered malformed events. The bounded strict reducer contract therefore uses a narrow native adapter; the comparator remains dev-only.
- ReqLLM v1.24.0 is a behavioral oracle, not a production dependency or parity commitment. A ReqLLM FFI backend remains a possible extension if clean Gleam packaging, Elixir startup, exception translation and common ownership tests justify it; no automatic backend adoption follows from source inspection.
- Jido AI v2.3.0 pins ReqLLM 1.17.1, so it does not establish an upstream-tested pairing with the v1.24.0 research snapshot. Claude Gleam's integrated loop/string handler and SDK tool loops do not replace the independent typed boundary.
- Exact selected cases and local assertions are recorded separately from exclusions. Pure scripted grammar proves transition laws; live OTP/HTTP fixtures establish named ownership/resource cases; sanitized commercial-provider cassettes establish named wire cases. None implies exhaustive runtime, provider, model or performance equivalence.

## Evidence

- The retained `test/anthropic_gleam_reuse_evaluation_test.gleam` executes the reuse comparison. Native-adapter delivery appears in [e643755](https://github.com/gleam-dream/llm_wire/commit/e643755a721d57152fd7bf61cbd9d9fccadb220c); initial experiment timing beyond the existing reports is not independently reconstructed here.
- ReqLLM annotated tag 29f855513c327ec5630a16215531ad2d459ae56e points to [fd9e079](https://github.com/agentjido/req_llm/tree/fd9e079fddf253e9b719b2d2c6920f4306592809), Apache-2.0. [Oracle guidance](../../test/oracle/README.md) retains license/pin and selected-case mapping; the full historical selection table remains at its immutable source revision.
- The [provider research](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/research/llm-provider-boundary.md), [streaming research](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/research/llm-streaming-contract.md) and ownership/laboratory records supply alternatives and evidence limits. Their upstream suites were not run wholesale.
- Wave reports/review diaries are consolidated into this record and ADR-0002; raw fixtures, exact test cases and receipts remain intact.
