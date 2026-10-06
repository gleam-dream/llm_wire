# Oracle inventory and reproduction

## Reference pins

- ReqLLM v1.24.0 is a selected behavioral comparator, not a dependency or parity commitment. Annotated tag `29f855513c327ec5630a16215531ad2d459ae56e` identifies commit [fd9e079fddf253e9b719b2d2c6920f4306592809](https://github.com/agentjido/req_llm/tree/fd9e079fddf253e9b719b2d2c6920f4306592809), Apache-2.0.
- Jido AI v2.3.0 pins ReqLLM 1.17.1. Its architecture is contextual evidence; it is not an upstream-tested pairing with the selected v1.24.0 snapshot. Neither complete upstream suite was executed.
- `anthropic_gleam` 0.1.1 is MIT and dev-only. `test/anthropic_gleam_reuse_evaluation_test.gleam` retains the public reuse experiment; event retention and malformed-event filtering prevented adopting its stream state. [ADR-0005](../../docs/adr/0005-native-reducers-and-bounded-oracles.md) owns the alternatives.
- [Google GenerateContent](https://ai.google.dev/api/generate-content), [function calling](https://ai.google.dev/gemini-api/docs/function-calling), [structured output](https://ai.google.dev/gemini-api/docs/structured-output) and [thought signatures](https://ai.google.dev/gemini-api/docs/generate-content/thought-signatures) are official protocol references, rather than ReqLLM parity evidence. [ADR-0004](../../docs/adr/0004-provider-schema-and-filter-semantics.md) identifies recorded provider/schema cases.

## Selected cases

- The [immutable original ledger](https://github.com/gleam-dream/llm_wire/blob/4726271d1671f48fe63222bc2133af1aacfe60e9/test/oracle/README.md) preserves exact upstream test names, detailed mappings and exclusions. The table below locates the retained executable assertions without reproducing a competing architecture corpus.

| Upstream selected law                                                    | Retained local evidence                                                        | Difference or limit                                                       |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Host contract: OpenAI/Anthropic equivalent text/tool/terminal interfaces | `llm_wire_openai_test`, `llm_wire_anthropic_test`, `llm_wire_integration_test` | Common laws only; no full provider parity                                 |
| Host contract: inspect tools and append results without execution        | integration caller-owned-turn tests; actual separate consumer                  | Application effects remain external                                       |
| Continuation: missing, duplicate and unknown result ids; call order      | integration/turn/API tests                                                     | Request-local validation replaces removed origin-bound checkpoint handles |
| SSE fields, frame splits and incomplete fragments                        | `llm_wire_sse_test`, `llm_wire_provider_fragmentation_test`                    | Framing and every two-chunk split for named complete provider text cases  |
| Responses message parts and structured tool output                       | `llm_wire_wave4_oracle_test` exact `req_llm_*_port` cases                      | Selected assertion ports; named local Google/cache cases are independent  |
| Complete/partial stream cleanup and cancellation                         | owner, HTTP Gun, pool/integration tests                                        | Different public ownership mechanism; no ReqLLM metadata-handle API       |
| Retry before bytes, refuse restart after data, status handling           | transport failure, advise, timers and consumer cases                           | LLM Wire never retries; only evidence/prospect laws are compared          |

## HTTP fixtures and raw evidence

- Dream commit [98a7103c60ce0767d6fc1630f4a58779c2360206](https://github.com/TrustBound/dream/tree/98a7103c60ce0767d6fc1630f4a58779c2360206) and ReqCassette commit [cb0251ca394952de46007bb32f5051feb66e896e](https://github.com/lostbean/req_cassette/tree/cb0251ca394952de46007bb32f5051feb66e896e), both MIT, informed original fixture laws. Their suites were not run wholesale and their file formats are not claimed compatible.
- HTTP Gun now owns binary fixtures, significant-header matching, recording and strict playback. Its current behavior supersedes donor-cassette text claiming headers were excluded or binary/live recording was absent; retained LLM cassette/recording tests exercise the public replacement.
- Keep exact request fixtures, malformed/fragmented SSE, offline live cassettes and `docs/evidence/http-gun/` source/runtime/red/green receipts. Historical complete-header rejection was post-parse evidence, not a pre-allocation guarantee.
- Exclusions include ReqLLM model discovery, Finch-specific policy, metadata wrappers, automatic retry counts, provider-native tool execution, image generation and unselected message/context formats. A newer model or extension needs its own named wire/ownership evidence.
- [Testing guidance](../../docs/testing.md) gives current commands. No historical test-count diary here substitutes for running the current package gate.
