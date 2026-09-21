# LLM Wire Wave 2 report

## Result

The tree now closes all seven blockers in the independent Wave 2 review with
named regressions: exact Blueprint schema serialization, terminal-only tool
batches, prepared-call-bound opaque continuations, opaque-prepared-call
transport entry points, typed provider terminal outcomes, read-timeout
arbitration, and a constructor-complete root facade. OpenAI refusal and
reasoning-summary deltas are also reduced; buffered refusal is exercised
through the public API. The previously interrupted tree was preserved from
`e5b7b0b`; no reset, commit, push, publication, credential use, or live provider
request occurred.

This report records blocker closure, not Wave 2 acceptance. The strict
pre-allocation HTTP-header bound, connection reuse, broader process-race and
provider/transport fragmentation coverage, full source-case inventory for
selected upstream oracles, and Google decision implementation remain open.
Exact test and limitation evidence is recorded below and in
`DESIGN-COVERAGE.md`.

## Public API evidence

The facade is `src/llm_wire.gleam`; provider request and continuation logic is
in `src/llm_wire/api.gleam`. A consumer can prepare and run without Fabric:

```gleam
import json/blueprint/codec
import llm_wire

let assert Ok(key) = llm_wire.api_key("secret-from-caller")
let assert Ok(endpoint) = llm_wire.endpoint("https://api.openai.com/v1")
let assert Ok(model) = llm_wire.model_id("model-name")
let config = llm_wire.openai_config(key, endpoint, None, None)
let assert Ok(name) = llm_wire.tool_name("lookup")
let assert Ok(tool) = llm_wire.tool_from_codec(
  name,
  "Look up one item",
  codec.field("id", codec.string()),
)
let request = llm_wire.new_request(model, [llm_wire.UserMessage("find item")])
  |> llm_wire.with_tools([tool])
let assert Ok(prepared) = llm_wire.prepare(
  config,
  request,
  llm_wire.default_limits(),
)
let result = llm_wire.run(
  prepared,
  llm_wire.default_limits(),
  llm_wire.default_deadlines(),
)
```

`stream`, `next`, and `close` expose the same owned semantic stream used by
`run`. Preparation lives in `api.gleam`; `runtime.gleam` passes only its opaque
`api.PreparedCall` to the internal client. That call captures the admitted
provider body, endpoint, headers, tool catalog, and TLS policy. The internal
client and transport modules do not accept caller-supplied request bodies or
routes. Gleam still permits importing modules marked internal, so the package
boundary relies on the opaque prepared value and restricted function
signatures, not on an import prohibition. `test/external_package_boundary.sh`
compiles a separate root-facade consumer and rejects a dependent package that
tries to fabricate a `PreparedCall`, pass a string body to the client, or pass
raw HTTP fields to the transport.

`RunToolCalls` carries a provider/model-bound continuation. The caller
executes application tools outside LLM Wire, creates one `ToolResult` for every
outstanding call, then calls `prepare_continue`. That function validates exact
coverage and the stored source calls before encoding the follow-up. Anthropic
continuations restore typed `tool_use` input and `tool_result`; OpenAI restores
`function_call` and `function_call_output`.

`prepare_structured` accepts a Blueprint codec, emits the provider JSON Schema
format, validates the response with the Blueprint runtime contract, then
decodes it with the native codec. Strict-schema forms that cannot be
represented without weakening the contract are rejected locally.

Provider request shape, exact transmitted schema, strict-output validation, and
Sinal metadata capture are exercised in `test/llm_wire_api_test.gleam`. A
consumer importing only `llm_wire` compiles constructor/configuration/request
preparation in
`root_facade_constructs_and_prepares_a_call_without_types_module_test`. The
`RunRefusal` result is exercised through `llm_wire.run`; `run_structured` maps
the same outcome to `StructuredRefusal`. `Continuation` is opaque and can only be
obtained from a tool-call run; its stored origin rejects substitution onto a
second otherwise identical prepared call.

## Review findings and regression evidence

The Wave 1 review findings were converted into regression tests in
`test/llm_wire_wave1_regression_test.gleam` and
`test/llm_wire_owner_test.gleam`:

- Tool catalog duplicates, undeclared names, schema-invalid JSON, and native
  decode errors fail before `ToolCallCompleted`.
- OpenAI duplicate output indices, contradictory item/index routes, and
  incomplete text items fail. Anthropic delta types must match their block.
- Progress queue saturation cannot replace an accepted provider terminal. The
  terminal uses a dedicated bounded state slot.
- Timed-out pending reads are removed; the same consumer can read again.
  Consumer death between reads stops the owner and closes the transport.
- The owner holds one outstanding read credit. A terminal queue never exceeds
  the progress queue’s configured bounds.
- Anthropic `server_tool_use` followed by a provider error returns
  `EffectUnknown`; no automatic retry path exists.

The ledger only marks implemented behaviors that have named local evidence.
The upstream oracle inventory remains selected rather than exhaustive.

## Wave 2 independent review closure

| Review finding                                           | Disposition and evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| -------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Transmitted tool schema disagreed with Blueprint         | Closed. `codec_schema_json_encodes_exact_blueprint_field_schema_and_numeric_bounds_test` compares the field and numeric projection; `codec_schema_projection_matches_blueprint_for_recursive_forms_test` compares each admitted recursive constructor, including nested nullable schemas, to `codec.schema_value`. Nullable `anyOf` ordering now follows Blueprint's canonical null-first projection.                                                                                                                                                                                                                    |
| A completed block exposed executable tool work early     | Closed. `ToolCallCompleted` was removed from public progress. Provider reducers retain each validated closed block internally and only publish the full `CompletedToolCalls` batch at terminal completion. OpenAI interleaving and Anthropic block tests cover this rule.                                                                                                                                                                                                                                                                                                                                                |
| Continuation could be fabricated or swapped across calls | Closed. The opaque continuation stores a reference assigned at preparation. `continuation_is_opaque_and_bound_to_its_prepared_interaction_test` obtains one from a real local HTTP call and rejects it for a separately prepared request with identical provider/model/tools.                                                                                                                                                                                                                                                                                                                                            |
| Public raw adapter bypassed request preparation          | Closed for supported package usage. The internal client and transport accept only opaque `api.PreparedCall`; neither accepts a body, host, path, or arbitrary header list from a caller. Prepared headers are created and checked during `api.prepare`; transport allows caller-selected plaintext or custom CA verification only for loopback hosts. `prepared_client_rejects_caller_ca_for_remote_host_test` checks the remote TLS boundary. The separate-package probe compiles root-facade preparation and fails when an external caller tries the former raw client/transport calls or fabricates the opaque token. |
| Provider terminal states were misclassified              | Closed for named cases. `OpenAI` refusal deltas produce `RunRefusal`, provider cancellation is a provider failure, Anthropic refusal is distinct, unknown stop reasons fail, and successful hosted effects retain `EffectUnknown`. Tests are in the OpenAI and Anthropic reducer suites plus the buffered refusal integration test.                                                                                                                                                                                                                                                                                      |
| Read timeout could discard already-accepted progress     | Closed for the reported inter-sender race. Reads carry a reference; owner acknowledgement arbitrates the timeout against delivery. `owner_read_timeout_delivery_race_never_loses_accepted_progress_test` runs arrival at the timeout boundary and proves progress is returned either by the current or next read.                                                                                                                                                                                                                                                                                                        |
| Root facade could not construct a call                   | Closed. `root_facade_constructs_and_prepares_a_call_without_types_module_test` imports only `llm_wire` and compiles key/model/endpoint/config/message/request/preparation/result construction.                                                                                                                                                                                                                                                                                                                                                                                                                           |

The findings are closed against the reproduced boundary conditions, not by
claiming comprehensive provider conformance. The exact remaining work-order
requirements are listed as open scope below.

## Transport and dependency decisions

The transport is a thin Erlang FFI around **Gun 2.6.0**, resolved in
`manifest.toml`. It uses Gun’s HTTP response parsing, stream reference,
`flow => 1`, `update_flow`, cancellation, TLS options, and connection messages.
It does not parse HTTP, JSON, SSE, or provider events itself. It sends one
request per connection and closes the connection on terminal cleanup; there is
no shared connection pool or reuse manager yet.

The local tests cover real HTTP/1.1 chunked transfer, loopback streaming for
both providers, refusal to follow 302 redirects, refusal of gzip responses,
bounded status-error bodies, a 429 `Retry-After: 3` hint, a 17 KB response
header block, total response-body limits, disconnects, setup deadline, pinned
CA success, untrusted CA failure, and hostname mismatch. TLS system verification
uses OTP public roots; pinned-CA mode uses `test/fixtures/llm-wire-test-ca.crt`.
Only HTTP/1.1 is negotiated. Decompression is intentionally refused rather than
performed without an explicit decompressed-size limit.

`anthropic_gleam` 0.1.1 was evaluated through its published sans-I/O request
builder and incremental handler in
`test/anthropic_gleam_reuse_evaluation_test.gleam`. Request construction and
normal fixture decoding work. Its public `StreamingState` accumulates all
events (`40` fed events remained in state), and `process_chunk` filters decode
errors rather than returning strict failures. Those semantics cannot sit behind
the bounded owner; the package is dev-only for this experiment.

Mist 6.0.2 is only a local HTTP/TLS test server. The Ewe 7.0.0 documentation
describes server APIs, so it is not an outbound client. Finch-Gleam 7.0.0’s
wrapper exposes streaming callbacks without a halt result; Finch 0.23 upstream
has `stream_while` and async cancellation, but adopting it would require wrapper
bindings and separate bounded-worker tests. These findings do not establish
that Finch itself is incapable. Gun remains the selected adapter.

Resolved direct versions include Gleam stdlib 0.71.0, gleam_json 3.1.0,
gleam_http 4.4.0, gleam_otp 1.3.0, Gun 2.6.0, Cowlib 2.20.0, and telemetry
1.4.2. `json_blueprint` 1.7.1 and Sinal 0.1.0 remain path dependencies.
`anthropic_gleam` 0.1.1 and Mist 6.0.2 are development dependencies.

### Header-limit caveat

Gun is configured with `max_header_block_size: 16_384`; the adapter also
measures the parsed response-header list and rejects it when it exceeds that
size. A local 17 KB complete header fixture is rejected. Inspection of the
resolved Gun 2.6.0 `gun_http.erl` shows that the parser checks its buffered
header size when no header terminator has arrived. A complete header section
that arrives in one receive can be assembled and parsed before the adapter’s
post-parse size check. Thus the test proves rejection and bounded socket-read
behavior, but it does not prove a strict 16 KiB pre-allocation cap. Satisfying
that exact bound needs a transport implementation or upstream change that
checks the complete block before assembly; this remains Wave 3 work.

## Google assessment

Google is deferred as the first required Wave 3 provider slice. The official
Generate Content API uses `contents[]` with role/parts and a provider-specific
`:streamGenerateContent` endpoint, so it needs its own request encoder and
candidate/part reducer while it can reuse the Gun transport and pure SSE
framer. The continuation collision is more specific: the API defines
`FunctionCall.id` as optional, but LLM Wire continuation requires an exact
identity for every outstanding call. The official function-calling guide says
Gemini 3 models always return IDs; older model profiles do not guarantee them.
Wave 3 must either make Gemini 3 the explicit supported profile or define a
safe correlation representation for responses without provider IDs.

Google’s structured-output API supports only a documented subset of JSON
Schema, so a Google adapter must reject schemas outside that subset rather
than send weakened schemas. Sources: [Generate Content API](https://ai.google.dev/api/generate-content),
[Gemini function calling](https://ai.google.dev/gemini-api/docs/function-calling),
and [Gemini structured output](https://ai.google.dev/gemini-api/docs/structured-output).

## Sinal observations

`src/llm_wire/telemetry.gleam` defines typed lifecycle stages for prepared,
request sent, first progress, terminal, cancelled, deadline, and cleanup.
Request-sent is emitted from the Gun bridge after `gun:post` returns. The event
schema contains only stage, provider, and fixed outcome metadata. Prompts,
tool arguments, bodies, credentials, and headers are not observation fields.
`lifecycle_observation_contains_only_fixed_metadata_test` captures the Sinal
event and checks its contents.

## Applied improvements and remaining friction

Applied during implementation:

- Replaced the interrupted raw TCP path with Gun and a typed FFI seam.
- Reworked terminal storage so a terminal does not exceed progress queue
  limits.
- Added whole-response, SSE event-count, retry-hint, header-count/byte, and
  provider request-body checks after review exposed gaps in the earlier limits.
- Removed the transport’s link to the caller; the bridge is monitored during
  setup and monitors its owner for cleanup.
- Added local TLS fixtures, Mist TLS peers, and end-to-end certificate tests.
- Moved `anthropic_gleam` to dev-only after measuring its retained-event
  behavior.
- Rewrote Blueprint schema serialization to preserve object closure, required
  fields, and numeric bounds, with a structural transmitted-schema regression.
- Removed executable per-block tool progress and bound opaque continuations to
  the originating prepared call.
- Added OpenAI refusal/reasoning reduction, Anthropic terminal-state handling,
  and owner acknowledgement for the read-timeout delivery race.
- Made internal client and transport entries accept only the opaque prepared
  call. Gleam still allows importing marked-internal modules, so a separate
  dependent-package regression proves raw request fields cannot cross those
  entry points. Preparation now captures validated headers with the body.
- Completed root-facade constructors/conversions and compiled a consumer that
  imports only the facade.
- Added every-byte-boundary tests for representative SSE frames and rewrote the
  coverage/oracle ledgers to name actual tests and retained gaps.

Implementer friction and decisions:

- A broad attempt to replace the root facade was rejected by automatic review
  because it could remove unrelated API. The implementation changed to targeted
  additive constructors/conversions and the root-only consumer passed.
- Gun 2.6.0 rejects an oversized parsed header but does not prove the strict
  pre-allocation contract for a complete header received at once. The adapter
  stayed thin; this limitation is reported rather than worked around with a
  second HTTP parser.
- The stream and connection lifetimes are separate. A shared Gun pool needs a
  connection/lease owner and broader shutdown tests, so no implicit reuse was
  added to the single-stream owner.

Not completed in this wave:

- Connection pooling/reuse, Google, strict pre-allocation header enforcement,
  the broad close/death/deadline race matrix, duplicate JSON-member tests,
  fragmented provider/transport cases beyond representative SSE framing, and
  exhaustive enumeration of every case in the selected upstream source files.
- No Hypothesis-style fuzz/property framework was added; deterministic
  regressions were kept focused on reported contract defects.

## Verification

- `nix develop --command gleam format --check src test`: **PASS**.
- `nix develop --command gleam check --target erlang`: **PASS**.
- `nix develop --command gleam test --target erlang`: **PASS**, 92 tests.
- `nix develop --command sh test/external_package_boundary.sh`: **PASS**;
  a separate package compiled the root-facade prepare path, while attempts to
  construct `api.PreparedCall`, pass a string body to the client, call the old
  raw client entry, or supply raw HTTP fields to the transport failed at
  compilation.
- `nix flake check`: **PASS** on `aarch64-darwin`. The check runs treefmt only;
  it does not replace the Gleam compiler or tests. Other Darwin/Linux systems
  were not checked by this local run.
- `git diff --check`: **PASS**.
