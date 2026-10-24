# Bound HTTP measurement claims to the local H2 fixture

<a id="adr-0015"></a>

## Decision and alternatives

- The local HTTP harness measures finite simultaneous demand and sibling cancellation against a verified H2 connection to a local nghttpd. It asserts semantic results, one H2 connection and cancellation isolation, and sets no speed ceiling. Provider generation latency, provider throughput, soak behavior and universal memory bounds are outside its claims.
- A latency threshold in the gate was rejected because timing depends on host and runtime and would make correct changes fail without a defect. Retaining only raw receipts without a stated workload was rejected because receipts alone do not say what was measured.

## Evidence and limits

- [BENCHMARKS.md](../BENCHMARKS.md) retains the workload, the method, how to run it, the recorded environment, the dated results table (2026-09-30, one batch per row, no repeat runs or confidence intervals) and the limits. Raw data stays in `docs/evidence/http-gun/` as non-markdown files.
- The retained run predates the facade and classification changes. A sampled VM peak is not a maximum-allocation bound, an earlier validation table has numbers whose relationship to this snapshot is unrecorded, so the two must not be combined as repeat samples, and a different source and host produce different numbers.
