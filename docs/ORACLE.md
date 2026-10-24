# Oracle references

LLM Wire compares selected behavior against pinned upstream implementations. No upstream suite runs wholesale, no reference is a dependency, and agreement on a named case is not parity. This page names each reference, what is compared, how outcomes are classified, what is excluded and how to rerun the comparison. [BENCHMARKS.md](BENCHMARKS.md) records the measured, non-asserting side of the evidence.

## Reference pins

| Reference                                                                                                                                                                                                                                                                                                                       | Pin                                                                                                                                                            | Licence      | Role                                                                                                                                                                       |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [ReqLLM](https://github.com/agentjido/req_llm) v1.24.0                                                                                                                                                                                                                                                                          | annotated tag `29f855513c327ec5630a16215531ad2d459ae56e`, commit [fd9e079](https://github.com/agentjido/req_llm/tree/fd9e079fddf253e9b719b2d2c6920f4306592809) | Apache-2.0   | Behavioral comparator for selected laws. Not a dependency or a parity commitment.                                                                                          |
| Jido AI v2.3.0                                                                                                                                                                                                                                                                                                                  | pins ReqLLM 1.17.1                                                                                                                                             | per upstream | Architecture context only. It is not an upstream-tested pairing with the v1.24.0 snapshot, and neither complete suite was executed.                                        |
| [`anthropic_gleam`](https://hex.pm/packages/anthropic_gleam) 0.1.1                                                                                                                                                                                                                                                              | Hex release                                                                                                                                                    | MIT          | Dev-only reuse experiment (`test/anthropic_gleam_reuse_evaluation_test.gleam`). It retained fed events and filtered malformed events, so its stream state was not adopted. |
| [Google GenerateContent](https://ai.google.dev/api/generate-content), [function calling](https://ai.google.dev/gemini-api/docs/function-calling), [structured output](https://ai.google.dev/gemini-api/docs/structured-output), [thought signatures](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures) | official documentation                                                                                                                                         | n/a          | Protocol references, not ReqLLM parity evidence.                                                                                                                           |
| [Dream](https://github.com/TrustBound/dream)                                                                                                                                                                                                                                                                                    | commit `98a7103c60ce0767d6fc1630f4a58779c2360206`                                                                                                              | MIT          | Informed the first fixture laws. Suite not run wholesale; no file format claimed compatible.                                                                               |
| [ReqCassette](https://github.com/lostbean/req_cassette)                                                                                                                                                                                                                                                                         | commit `cb0251ca394952de46007bb32f5051feb66e896e`                                                                                                              | MIT          | Informed the first fixture laws. Suite not run wholesale; no file format claimed compatible.                                                                               |

The exact upstream test names, detailed mappings and exclusions of the original ledger stay at its [immutable source revision](https://github.com/gleam-dream/llm_wire/blob/4726271d1671f48fe63222bc2133af1aacfe60e9/test/oracle/README.md).

## What is compared and how outcomes are classified

Each row pairs one selected upstream law with retained local assertions. An outcome is one of three kinds: the local assertion matches the upstream law, the local assertion keeps the law with a stated difference, or the law is excluded below.

| Upstream selected law                                                             | Local evidence                                                                             | Difference or limit                                                      |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| Host contract: OpenAI and Anthropic equivalent text, tool and terminal interfaces | `llm_wire_openai_test`, `llm_wire_anthropic_test`, `llm_wire_integration_test`             | Common laws only; no full provider parity                                |
| Host contract: inspect tools and append results without execution                 | integration caller-owned-turn tests; the [public consumer](../examples/consumer/README.md) | Application effects remain external                                      |
| Continuation: missing, duplicate and unknown result ids; call order               | integration, turn and API tests                                                            | Request-local validation replaces origin-bound checkpoint handles        |
| SSE fields, frame splits and incomplete fragments                                 | `llm_wire_sse_test`, `llm_wire_provider_fragmentation_test`                                | Framing and every two-chunk split for named complete provider text cases |
| Responses message parts and structured tool output                                | `llm_wire_oracle_port_test` exact `req_llm_*_port` cases                                   | Selected assertion ports; named Google and cache cases are independent   |
| Complete and partial stream cleanup and cancellation                              | owner, HTTP Gun, pool and integration tests                                                | Different public ownership mechanism; no ReqLLM metadata-handle API      |
| Retry before bytes, refuse restart after data, status handling                    | transport failure, advise, timers and consumer cases                                       | LLM Wire never retries; only evidence and prospect laws are compared     |

Pure scripted grammar proves transition laws. Live OTP and HTTP fixtures establish named ownership and resource cases. Sanitized commercial-provider cassettes establish named wire cases at their recorded revision and model. None of these implies exhaustive runtime, provider, model or performance equivalence.

## Exclusions and deliberate differences

- ReqLLM model discovery, Finch-specific policy, metadata wrappers, automatic retry counts, provider-native tool execution, image generation and unselected message and context formats are excluded.
- HTTP Gun now owns binary fixtures, significant-header matching, recording and strict playback. Its current behavior supersedes donor-cassette text that claimed headers were excluded or binary and live recording were absent.
- A newer model or extension needs its own named wire and ownership evidence.
- A ReqLLM FFI backend remains a possible extension only if clean Gleam packaging, Elixir startup, exception translation and common ownership tests justify it.

## Preserved inputs

Exact request fixtures, malformed and fragmented SSE, offline live cassettes under `test/cassettes/live/` and the source, runtime and local HTTP JSON receipts under `docs/evidence/http-gun/` stay as retained inputs. The harness writes its logs under `build/local-http/`, which is not retained. `docs/evidence/http-gun/sources.json` is a dated receipt of the 2026-09-30 capture: its file hashes describe the sources at that capture and are not refreshed. Historical complete-header rejection was post-parse evidence, not a pre-allocation guarantee.

## Run the comparison

From the package root, in the pinned Nix shell:

```sh
nix develop -c gleam test
nix develop -c sh dev/gate fast
```

Neither command contacts a provider or a reference repository. Recording new cassettes is a separate opt-in operation (`dev/record-live`) that spends provider tokens and needs explicit authorization.

## Limits of the claim

A passing comparison establishes the named case at the pinned revisions and the recorded runtime. It does not establish upstream conformance beyond the table, nor behavior of later versions of any reference.

## Where the decisions live

- [Observability and verification, Oracle evidence](design/design.typ) states the rule.
- [ADR 0005](adr/0005-native-reducers-and-bounded-oracles.md) records the alternatives and why narrow native reducers won.
- [ADR 0004](adr/0004-provider-schema-and-filter-semantics.md) identifies the recorded provider and schema cases.
- [ADR 0013](adr/0013-qualify-with-offline-replay-and-a-public-consumer.md) records offline replay and the public consumer.
- [AGENTS.md](../AGENTS.md) lists the gate commands.
