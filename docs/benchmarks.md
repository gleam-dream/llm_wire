# Local HTTP benchmark results

These are retained measurements from 2026-09-30, before the current facade and
classification changes. They measure a local TLS/H2 fixture; provider generation
latency is outside this workload. The numbers below come directly from
[local-http.json](evidence/http-gun/local-http.json).

## Workload and results

The harness releases 1, 10, 100 and 1,000 caller processes from a barrier. Each
runs one prepared custom-provider request whose small fixed SSE response yields
`hello`. The calls share one verified H2 connection to local `nghttpd`, with a
peer limit of eight streams and client active/waiting limits of 2,048 each. A
separate 2 MiB text stream remains unread during these batches. Another scenario
cancels one long stream while a sibling collects its full 2 MiB response.

Each row is one batch, with one duration per caller. There are no retained repeat
runs or confidence intervals for this receipt. Batch elapsed time spans barrier
release through collection of all results; call latency surrounds `llm_wire.run`.
The p50 and p95 select sorted durations at rank
`max(1, floor(callers * percentile / 100))`.

| Callers | Failures | Batch elapsed (ms) | p50 (ms) | p95 (ms) | Maximum (ms) | Sampled VM peak (MiB) |
| ------- | -------- | ------------------ | -------- | -------- | ------------ | --------------------- |
| 1       | 0        | 1.156              | 0.763    | 0.763    | 0.763        | 60.02                 |
| 10      | 0        | 1.471              | 1.180    | 1.376    | 1.407        | 58.49                 |
| 100     | 0        | 13.606             | 8.873    | 13.291   | 13.506       | 62.12                 |
| 1,000   | 0        | 123.623            | 63.682   | 111.050  | 116.021      | 98.06                 |

Resource sampling covers the whole Erlang VM at 10 ms intervals. Short batches
can finish between samples, so a sampled peak is not a maximum-allocation bound.
The receipt also retains process memory, mailbox, process-count and port samples.

## Recorded environment and source

[Runtime metadata](evidence/http-gun/runtime.json) records Darwin ARM64 25.5.0,
Gleam 1.18.1, OTP 28.5.0.6 / ERTS 16.4.0.6, rebar3 3.27.0 and nghttpd/nghttp2
1.70.0. CPU model, RAM, scheduler settings and Python version were not recorded.

[Source hashes](evidence/http-gun/sources.json) identify the measured working-tree
files relative to base `bbde1d927675e3fe55dcbc5f456a9bcb6fe24107`, with HTTP Gun at
`ebf2b479761e8c932b0c85a8f83cf8460c014d4f`. The base commit alone does not identify
the measured source. [Donor provenance](evidence/http-gun/donor-source.json)
retains Apache-2.0 attribution for the local-server and VM-sampling patterns.

The [historical validation table](https://github.com/gleam-dream/llm_wire/blob/4726271d1671f48fe63222bc2133af1aacfe60e9/docs/http-gun-validation.md#practical-concurrency)
has different numbers. Its precise relationship to this raw snapshot is not
recorded, so the two tables must not be combined as repeat samples. The current
harness also has an explicit 30-second pool wait; the retained JSON does not
record a pool timeout. These measurements are finite local observations; they
do not establish provider throughput, a soak result or a universal memory bound.

## Reproduce the workload

From the package root, with local sibling dependencies and the pinned Nix shell:

```sh
nix develop -c gleam build
nix develop -c python3 dev/local-http.py
```

The current [harness](../dev/local-http.py), [consumer](../test/llm_wire_local_gate.gleam)
and [VM sampler](../test/llm_wire_measure_ffi.erl) are executable inputs. The
harness writes `docs/evidence/http-gun/local-http.json` and a bounded server-log
prefix; preserve the retained receipt before collecting a new run. The current
source and host can produce different numbers. No benchmark was rerun for this
documentation change.
