# LLM Wire Wave 2 Progress

Status: reported review blockers have regression-backed corrections; independent acceptance review pending. Unfinished work-order scope remains open below.
Checkpoint: `e5b7b0b`. Interrupted working-tree changes were inspected and retained.

## Completed with regression proof

- Blueprint-backed tool catalog admission, duplicate-name rejection, exact
  provider JSON Schema serialization, full JSON validation, and native codec
  decoding before a tool call becomes executable.
- OpenAI and Anthropic reducers retain complete tool requests until the terminal
  batch; no per-block executable tool-call progress exists.
- OpenAI routing, text/refusal/reasoning block completion, Anthropic delta/block
  type agreement, provider refusal/cancellation/hosted-effect terminals, and
  first-terminal preservation have named regression evidence.
- Bounded one-credit Gun streaming, owner queue limits, per-chunk event-count
  limit, total response-body limit, owner-acknowledged timed-read arbitration,
  consumer monitoring, transport-owner monitoring, cancellation, and idempotent
  close.
- OpenAI Responses and Anthropic Messages `prepare`, `run`, `stream`, `next`,
  `close`, provider-bound continuation, and strict structured output APIs.
- Gun 2.6.0 HTTP/TLS adapter, local chunked transfer, redirect refusal,
  compression refusal, bounded status bodies and `Retry-After`, local pinned-CA
  success, hostname failure, setup deadline, disconnect, header and body cases.
- Every single-byte split of representative LF and CRLF SSE frames.
- Root-facade-only consumer compilation and a buffered API refusal round-trip.
- Sinal lifecycle observations and metadata redaction test.
- `anthropic_gleam` 0.1.1 public sans-I/O experiment. Its request builder is
  viable, but its streaming state retains all events and its decoder filters
  malformed events; dependency moved to dev-only.
- Coverage and oracle ledgers rewritten to name actual tests and remaining gaps.

## Review-finding disposition

| Finding                                      | Wave 2 status                                                                                                                                      |
| -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Finding                                      | Wave 2 disposition                                                                                                                                 |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------   |
| Blueprint schema mismatch                    | Closed: provider schema structurally equals Blueprint's closed, required field schema; exact numeric bounds are JSON numbers.                      |
| Tool calls escaped before a safe batch       | Closed: executable calls are delivered only through terminal `CompletedToolCalls` after all declared blocks validate.                              |
| Forgeable/cross-call continuation            | Closed: opaque continuation carries an unforgeable prepared-call reference; fake-server regression rejects an otherwise identical prepared call.   |
| Public plaintext/preparation bypass          | Closed at supported package boundary: raw client/transport moved under `internal` and independently reject remote plaintext and malformed inputs.  |
| Provider terminal misclassification          | Closed for named cases: refusal, unknown stop reasons, hosted-effect uncertainty, and provider cancellation retain distinct outcomes.              |
| Read-timeout delivery race                   | Closed for the reported race: per-read identity and owner acknowledgement decide whether accepted progress or timeout wins.                        |
| Root facade cannot construct a call          | Closed: consumer test imports only `llm_wire`, configures, constructs, and prepares a call.                                                        |
| Header/body bounds                           | Partial: response body and parsed header size are enforced; strict pre-allocation cap for complete oversized Gun headers remains unproved.         |
| Transport reuse                              | Open: one request per Gun connection; pooling needs a distinct connection/lease owner.                                                             |
| Race/split/oracle coverage                   | Partial: representative SSE every-byte boundaries and read-timeout arbitration added; broader provider/transport race and source inventory remain. |

## Open Wave 3–5 work

- Wave 3: Google adapter/model profile, strict pre-growth header bounds or a
  transport that proves them, broad process-race coverage, duplicate
  JSON-member and tool-argument-disconnect tests, and complete selected-oracle
  source-case inventory.
- Wave 4: connection reuse/pooling, with a distinct lease/connection owner.
- Wave 5: multimodal content and WebSocket/realtime protocols.

Final verification against the report and coverage edits:

- `nix develop --command gleam format --check src test`: PASS.
- `nix develop --command gleam check --target erlang`: PASS.
- `nix develop --command gleam test --target erlang`: PASS, 90 tests.
- `nix flake check`: PASS on `aarch64-darwin` (treefmt only).
- `git diff --check`: PASS.
