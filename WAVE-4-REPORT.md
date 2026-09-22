# LLM Wire Wave 4 report

## Outcome

Wave 4 closed a coherent first capability slice on top of baseline `188c70b`.
The package now carries typed mixed text and image input parts, provider-scoped
prompt-cache references, and Gemini's opaque `thoughtSignature` state through a
tool continuation. The existing Gun lease pool also received a necessary
state-shape repair found by the new timing. Selected ReqLLM behaviors were
ported into executable Gleam cases and run in the normal package suite.

This is partial Wave 4 delivery. Embeddings, durable continuation, automatic
retry, Anthropic cache breakpoints, detailed usage parity, and separate
batch/background/realtime transports remain open or are recorded as complexity
candidates below. This report does not self-accept the wave.

## Implemented behavior

The internal `ToolCall` keeps application ID, provider routing ID, and opaque
provider state as separate values. The public root facade keeps its stable
three-field `ToolCall` shape. Google reduction accepts valid `thoughtSignature`
values on signed text and function-call parts, rejects malformed signature
values as typed protocol errors, and retains the complete signed model-part
sequence for continuation. The loopback continuation test requires the raw
signed model parts in their original order in the second local request.

`Content` now has text, remote image URL, and inline base64 image variants.
OpenAI Responses encodes user text as `input_text`, assistant text as
`output_text`, and admitted image parts as `input_image`. Anthropic
Messages and Google GenerateContent encode text and inline image blocks. A
remote URL outside either adapter's current admitted profile fails during
preparation with a typed error; the Anthropic message names this as an adapter
profile boundary because the upstream provider has URL image forms. The
content wire remains ordinary Gleam JSON assembled by the existing adapter
encoders. Blueprint remains the schema-bearing domain boundary for tools and
structured output; it is not used as an envelope JSON abstraction.

`PromptCache` makes provider identity explicit. `OpenAiPromptCacheKey` becomes
`prompt_cache_key`, and `GoogleCachedContent` becomes `cachedContent`. A cache
variant selected for another provider fails before transport. Anthropic's cache
breakpoints are content-block metadata rather than a request reference and are
therefore left for a separate typed slice.

The pool connector now has a state-returning helper for waiter callbacks. The
previous callback path could place `{noreply, State}` inside the GenServer state
when serving a waiter after a connection result or cleanup event. The repair
preserves the `handle_call` reply tuple and prevents the resulting pool crash
and spurious `noproc` shutdown result.

## Oracle ports

The source oracle is ReqLLM v1.24.0, annotated tag object
`29f855513c327ec5630a16215531ad2d459ae56e`, tagged commit
`fd9e079fddf253e9b719b2d2c6920f4306592809`, Apache-2.0. The pinned checkout is
`/private/tmp/req_llm_v1.24.0_oracle`; its full ExUnit suite was not run and no
live provider or credential was used.

The following selected behaviors are ported and run as
`test/llm_wire_wave4_oracle_test.gleam`:

- `test/req_llm/message_test.exs` — assistant messages with multiple content
  parts, adapted by
  `req_llm_message_test_assistant_message_with_multiple_content_parts_port`.
- `test/provider/openai/responses_api_unit_test.exs` — structured tool outputs
  from context metadata, adapted by
  `req_llm_responses_api_test_encodes_structured_tool_outputs_port`.
- `test/provider/openai/responses_api_unit_test.exs` — input message role and
  content encoding, adapted by
  `req_llm_responses_api_test_encodes_input_messages_port`.

The local Wave 4 suite separately covers Google model/user tool-turn ordering,
inline data-URI admission, Gemini `cachedContent` encoding, provider-state
reduction, malformed signature failure, and the pooled waiter cleanup callback.
Those cases are labeled local because their selected upstream triggers differ;
the complete oracle ledger is in `test/oracle/README.md`.

## `dwmkerr/mock-llm` sanity probe

The requested primary-repository inspection used the upstream [README and
repository](https://github.com/dwmkerr/mock-llm), its [`src/` entry](https://github.com/dwmkerr/mock-llm/tree/main/src), and its
[`test-samples.spec.ts` entry](https://github.com/dwmkerr/mock-llm/blob/main/test-samples.spec.ts), plus the published package metadata at
[@dwmkerr/mock-llm](https://www.npmjs.com/package/%40dwmkerr/mock-llm). The
package is MIT licensed. The README and sample contract describe
`POST /v1/chat/completions`, OpenAI Chat Completions `messages` and
`choices` payloads, sequence-based tool-call examples, and Chat Completions
SSE chunks; the README says Responses support could be added later.

That server therefore has no verified endpoint overlap with this package's
OpenAI Responses `/v1/responses`, Anthropic Messages `/v1/messages`, or Google
GenerateContent adapters. A Chat Completions request cannot serve as a
Responses sanity check because its request and SSE response envelopes differ.
No mock-llm process was started and no dependency was added: a local run would
only prove an unsupported route or require a new adapter surface. ReqLLM's
pinned, exact trigger-and-assertion ports remain the applicable external
behavioral evidence for this slice.

## Header bound investigation

The resolved dependency is Gun `2.6.0` with Cowlib `2.20.0`. In the pinned
source, Gun's HTTP/1 handler accumulates bytes until a complete header terminator
is found. When no terminator is present it compares the accumulated byte size
with `max_header_block_size` (default `100000`). Once a terminator is present,
the complete block is passed to `handle_head/5`, which calls
`cow_http:parse_status_line/1` and `cow_http:parse_headers/1`; only afterward
does Gun apply `max_headers`.

The local 17 KiB one-write fixture therefore proves post-parse rejection by the
LLM Wire limit. It does not prove a pre-parse allocation ceiling. HTTP/2 uses
Cowlib's header-block decoder and has a separate fragmented-block bound. No
second parser or dependency fork was added. The simple options are an upstream
Gun/Cowlib seam that checks complete blocks before parsing, or a maintained
transport with a documented pre-parse bound. Both require a separate dependency
decision; the current adapter does not claim the strict allocation guarantee.

## Complexity register

| Requirement                                | Concrete machinery                                                                                                                                                                             | Standard alternative                                                                | Decision and maintenance cost                                                                                                                                                                                     |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Embeddings                                 | Add a typed unary `embed` request/result with provider paths, vectors, limits, and ordinary JSON decoders.                                                                                     | Keep the existing streaming `PreparedCall` path and make callers use provider SDKs. | Deferred as a small independent endpoint candidate. OpenAI, Anthropic, and Google shapes and error/usage fields need a separate matrix and oracle fixtures; forcing it into streaming would add misleading state. |
| Anthropic prompt caching                   | Add content-block cache breakpoint metadata and encode `cache_control` on the selected block.                                                                                                  | Continue with explicit OpenAI/Gemini request references only.                       | Deferred. The common request-reference sum cannot express block placement without a typed content contract change; silently dropping it would be wrong.                                                           |
| Durable/versioned continuation             | Serialize provider/model identity, source calls, provider IDs/state, response ID, and conversation in a versioned ordinary JSON envelope; restore only with compatible prepared configuration. | Keep continuation opaque and process-local.                                         | Deferred. Restoration needs a public compatibility/error contract and bounded decoding; live sockets and credentials must stay out.                                                                               |
| Automatic retry                            | Add a bounded policy around failures before accepted progress, with remaining-deadline accounting and explicit replay ownership.                                                               | Expose current `RetryEvidence` and let the caller decide.                           | Deferred. A stream failure does not prove provider-side effects; automatic replay would need a caller opt-in and idempotency policy.                                                                              |
| Batch/background operations                | Add submit/status/cancel identities and polling state.                                                                                                                                         | Keep one streaming request per `PreparedCall`.                                      | Deferred. This is a separate durable job protocol with provider-specific endpoints and cancellation semantics.                                                                                                    |
| Realtime/WebSocket and remote cancellation | Add bidirectional framing, reconnect/state, and provider acknowledgement.                                                                                                                      | Keep Gun SSE and report local cancellation only.                                    | Deferred. It is a separate transport/state machine; SSE close cannot claim remote cancellation.                                                                                                                   |
| Strict response-header allocation bound    | Patch the Gun/Cowlib seam or replace transport.                                                                                                                                                | Retain the existing bounded post-parse adapter limit.                               | Decision required from maintainers. No internal second parser was introduced; current proof and limitation are recorded above.                                                                                    |

## Verification

All commands below were awaited synchronously:

- `nix develop --command gleam format src test` — pass.
- `nix develop --command gleam check --target erlang` — pass.
- `nix develop --command gleam build --target erlang` — pass.
- `nix develop --command gleam test --target erlang` — 133 passed, no failures.
- `nix develop --command sh test/external_package_boundary.sh` — pass; the
  facade consumer compiled and raw PreparedCall/transport misuse failed at the
  intended boundary.
- `nix flake check` — pass for the available `aarch64-darwin` check; Nix
  omitted incompatible Linux and x86 systems.
- `git diff --check` and `git diff --cached --check` — pass.

The suite emits expected TLS alert/supervisor notices from negative local TLS
fixtures and still exits successfully. No commit, push, sibling edit, remote
provider call, or real credential use occurred. The coordinating task should
obtain the independent Sol Medium review before treating this implementation
as accepted.
