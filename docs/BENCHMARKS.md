# Benchmarks

LLM Wire retains one finite, non-asserting measurement: a local HTTP workload. It measures simultaneous callers sharing one HTTP/2 connection and the isolation of a cancelled stream, not provider latency. The workload sets no speed ceiling and no gate fails on timing. [ORACLE.md](ORACLE.md) records the comparison references that sit beside it.

## Scope

- Measured: finite simultaneous demand (1, 10, 100 and 1,000 callers) and sibling cancellation against a verified H2 connection to a local `nghttpd`.
- Not measured: provider generation latency, provider throughput, soak behavior and any universal memory bound.
- Acceptance checks semantic results, one H2 connection and cancellation isolation. Timing has no threshold, because timing depends on the host and runtime and a threshold would fail correct changes ([ADR 0015](adr/0015-bound-http-benchmark-claims-to-the-local-fixture.md)).

## Method

The harness releases the caller processes from a barrier. Each runs one prepared custom-provider request whose small fixed SSE reply yields `hello`. The calls share one verified H2 connection to a local `nghttpd`, with a peer limit of eight streams and client active and waiting limits of 2,048 each. A separate 2 MiB text stream stays unread during these batches. One further scenario cancels a long stream while a sibling collects its full 2 MiB response.

Each row is one batch with one duration per caller. Batch elapsed time spans barrier release through collection of all results; call latency surrounds `llm_wire.run`. The p50 and p95 select sorted durations at rank `max(1, floor(callers × percentile / 100))`. VM resource sampling covers the whole Erlang VM at 10 ms intervals, so a sampled peak is not a maximum-allocation bound.

## Run the workload

From the package root, with local sibling dependencies and the pinned Nix shell:

```sh
nix develop -c gleam build
nix develop -c python3 dev/local-http.py
```

The [harness](../dev/local-http.py), [consumer](../test/llm_wire_local_gate.gleam) and [VM sampler](../test/llm_wire_measure_ffi.erl) are the executable inputs. The harness writes a fresh ignored `build/local-http/` directory; select another with `--output PATH` or `LLM_WIRE_HTTP_OUTPUT`, and a reused directory fails. The receipt records source and sibling revisions with dirty flags, lockfile hashes, runtime and OS versions, raw consumer output and a bounded server-log prefix. The full CI gate runs this finite workload on pushes, pull requests and manual runs, and the weekly schedule retains current observations.

## Environment of the retained run

Darwin ARM64 25.5.0, Gleam 1.18.1, OTP 28.5.0.6 / ERTS 16.4.0.6, rebar3 3.27.0, nghttpd 1.70.0. CPU model, RAM, scheduler settings and the Python version were not recorded. The measured source is identified by working-tree file hashes relative to base `bbde1d927675e3fe55dcbc5f456a9bcb6fe24107` with HTTP Gun at `ebf2b479761e8c932b0c85a8f83cf8460c014d4f`, because the base commit alone does not identify the measured source.

## Retained results (2026-09-30)

One batch per row, with no repeat runs and no confidence intervals. The run predates the current facade and classification changes.

| Callers | Failures | Batch elapsed (ms) | p50 (ms) | p95 (ms) | Maximum (ms) | Sampled VM peak (MiB) |
| ------- | -------- | ------------------ | -------- | -------- | ------------ | --------------------- |
| 1       | 0        | 1.156              | 0.763    | 0.763    | 0.763        | 60.02                 |
| 10      | 0        | 1.471              | 1.180    | 1.376    | 1.407        | 58.49                 |
| 100     | 0        | 13.606             | 8.873    | 13.291   | 13.506       | 62.12                 |
| 1,000   | 0        | 123.623            | 63.682   | 111.050  | 116.021      | 98.06                 |

Raw data stays as non-markdown files: [local-http.json](evidence/http-gun/local-http.json), [runtime.json](evidence/http-gun/runtime.json), [sources.json](evidence/http-gun/sources.json) and [donor-source.json](evidence/http-gun/donor-source.json) (Apache-2.0 attribution for the local-server and VM-sampling patterns). The receipt also retains process memory, mailbox, process-count and port samples.

## Limits

These are finite local observations. A different source and host produce different numbers, and a sampled peak is not an allocation maximum. An earlier validation table has different numbers whose relationship to this snapshot is unrecorded, so the two must not be combined as repeat samples. The harness has since gained an explicit 30-second pool wait that the retained JSON does not record.

## Where the decisions live

- [Observability and verification, Local HTTP measurement](design/design.typ) states the rule.
- [ADR 0015](adr/0015-bound-http-benchmark-claims-to-the-local-fixture.md) records the decision and the rejected alternatives.
- [AGENTS.md](../AGENTS.md) lists the gate commands.
