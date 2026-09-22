# LLM Wire Wave 4 focused rereview

## Verdict

All four review findings are closed. Google now retains the complete signed
model-part sequence and rejects malformed signatures, Blueprint's
`codec.schema_value` is the sole schema projector, the pool repair has a
deterministic cleanup-callback regression, and all three ReqLLM ports retain
their selected upstream assertions. The focused Wave 4 correction set is
**accepted**.

This is a focused rereview of the findings in `llm-wire-wave4-review.md`, not a
new full-package review. The installed review skill's mandatory primitive
files remain unavailable, so the rereview uses direct source, upstream-test,
and executable-gate evidence without inventing the missing rubric.

## Finding status

### Closed — Google signed-part retention and malformed signature handling

`src/llm_wire/google.gleam:292-334` now distinguishes an absent
`thoughtSignature` from a present value of the wrong type. A malformed value
returns a typed `ProtocolError`. Every decoded model part is retained as
provider-owned JSON in arrival order, including signed text and other non-tool
parts. At a tool terminal, `google.gleam:485-527` places the ordered parts in a
`GoogleProviderContinuation`.

`src/llm_wire/api.gleam:479-539,1169-1269` carries that continuation through
the opaque prepared interaction and substitutes the complete retained model
turn at the corresponding assistant-tool-call position before the ordered
function responses. The signature remains on its original part; application
call IDs, provider call IDs, and provider continuation state remain separate.

The focused reducer tests cover a signed text part followed by a signed
function-call part, their order, and a non-string signature error. The local
two-request test checks the exact retained signed function-call part and the
provider call ID in the prepared continuation body. This closes the original
finding for the implemented tool-continuation path. Durable serialization and
non-tool final-turn persistence remain outside this accepted subset as already
reported.

### Closed — Blueprint is the single schema projection authority

`src/llm_wire/schema.gleam:13-47` now begins every schema-bearing wire value
with `codec.schema_value(schema)`. The local recursion converts Blueprint's
`value.Value` representation into ordinary `gleam/json`; it does not recreate
the schema AST projection. Tool and structured-output profile functions now
validate their admitted subset and then call that same bridge.

This meets the intended boundary: Blueprint owns schema semantics and runtime
validation, while ordinary provider envelopes continue to use Gleam JSON. No
strict envelope abstraction or duplicate schema renderer was introduced.

### Closed — all three ReqLLM ports retain their selected assertions

The revision and Apache-2.0 provenance remain exact. Two replacement ports now
retain their selected upstream triggers and observations:

- The assistant multi-content case constructs the same ordered assistant text
  and URL-image parts and proves both remain admitted and encoded.
- The Responses structured-tool-output case constructs the same call identity
  and structured result and proves the `function_call_output` contains that
  call ID and JSON output.

The rich continuation comparator is now honestly labeled local rather than an
upstream port. That resolves the provenance overclaim for that case.

Its replacement uses pinned ReqLLM
`test/provider/openai/responses_api_unit_test.exs:796-818`, “encodes input
messages correctly.” Both upstream and local cases construct ordered user and
assistant text messages, then assert that the user block is `input_text` and
the assistant block is `output_text`. The first rereview exposed that the
initial replacement incorrectly expected `input_text` for both roles. The
source now selects the text content type by role, and
`test/llm_wire_wave4_oracle_test.gleam:64-81` asserts the exact upstream role,
order, content type, and text values.

Together with the assistant multi-content and structured tool-output cases,
this supplies three faithful executable ReqLLM ports. Provider-specific Google
continuation ordering remains correctly classified as local evidence.

### Closed — pool waiter callback regression

`test/llm_wire_pool_test.gleam:443-530` deterministically leases the only
connection, queues a waiter, kills the checked-out stream owner, and requires
the cleanup callback to start a replacement connection that serves the waiter.
It then reads pool state and stops the still-callable pool successfully.

This reaches the corrected `maybe_serve_waiter/1` connector branch rather than
the older checked-in-idle-connection path. Together with the helper split in
`src/llm_wire_gun_pool.erl`, it closes the state-tuple crash finding.

## Mock LLM assessment

The `dwmkerr/mock-llm` section is appropriately bounded. Its README documents
`POST /v1/chat/completions`, Chat Completions request/choice envelopes,
sequence-based tool examples, and Chat Completions SSE behavior. It says
Responses support is future extension work. LLM Wire uses OpenAI Responses,
Anthropic Messages, and Google GenerateContent, so the report makes no endpoint
or payload compatibility claim, did not run the server, and did not add a
dependency. That is the correct disposition for this wave.

## Independent verification

- `nix develop --command gleam test --target erlang` — **133 passed, no
  failures**. Expected negative TLS fixture notices were emitted.
- `nix develop --command sh test/external_package_boundary.sh` — passed; the
  root facade compiled and raw prepared-call/transport construction failed at
  the intended boundary.
- `nix flake check` — passed the available `aarch64-darwin` check; Nix omitted
  incompatible systems.
- `git diff --check 188c70b` and `git diff --cached --check` — passed.

## Acceptance boundary

Accept the Google continuation correction, Blueprint projection correction,
pool callback correction, and all three replacement ReqLLM ports. The rich
continuation test is correctly classified as local. This accepts the focused
Wave 4 correction set, not the full retained package scope.

The wider Wave 4 boundary remains unchanged: multimodal and provider-option
parity, embeddings, Anthropic cache breakpoints, detailed usage/reasoning/stop
coverage, durable continuation, replay-safe retry, lifecycle observations,
batch/background operations, remote cancellation, realtime, and release
hardening remain open. The response-header pre-allocation question remains the
recorded dependency decision; this rereview adds no fork, parser, or new
requirement.
