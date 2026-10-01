# Fabric migration to caller-owned conversations

The owner assigned agent continuation and persistence to Fabric on 2026-09-29.
This is the integration work for Fabric; its source is not changed by this wire
library revision. The authoritative wire contract is
[caller-owned-conversation.md](caller-owned-conversation.md).

## Port changes

- Replace a stored `session.Continuation` with the original request plus the
  returned `types.AssistantTurn`. The turn is response data, with provider, text,
  calls, response ID, provider data, and call issues.
- Read `turn.calls` for tool dispatch and `turn.issues` for reported invalid calls.
  Store effect/results under Fabric's execution and round IDs. Provider call IDs
  may repeat in separate rounds.
- Append `types.AssistantTurnMessage(turn)` and one `ToolResultMessage` per call
  to Fabric's conversation. Prepare the next request with explicit configuration,
  catalog, options, and structured output codec. No native output codec is hidden
  in a pending wire handle.
- Keep each turn's provider data with its original calls and text. Google signed
  parts cannot be reconstructed from a text-only transcript. A Fabric persistence
  format must preserve these fields and own versioning, compatibility, trust, and
  transactional recovery. LLM Wire supplies no durable checkpoint schema.
- When a tool batch is incomplete, retain it in Fabric; do not submit it as a new
  wire request. Wire preparation rejects incomplete result coverage before I/O.

## Test and deployment composition

Inject pure provider `config.Config` and an application-owned `http_gun.Client`
into the same agent flow. Start/supervise the client once and pass it to `run`,
`stream` and their structured counterparts. Set its deadline ceiling to cover
Fabric's longest LLM budget. Put trust and connection policy at client startup;
remove the old pool/CA/idle-eviction settings.

Use HTTP Gun script clients or load its current cassette schema and start strict
playback. `llm_wire/testing` now supplies pure semantic replies and
`testing.exchange` / `structured_exchange`. Inspect those bounded expected
exchanges rather than an accumulating `testing.requests` history. Startup handles
fixture failures. For recording, pass `recorded.client` and finalize separately
after all streams are consumed/closed; capture failure must not overwrite the
agent's successful response. Missing matches never authorize live calls.

The [compiled consumer](../examples/consumer/src/llm_wire_consumer.gleam) shows
shared supervision, early close, concurrency and all four startup modes. Fabric
has not been modified or independently validated by this migration.

## Consumer acceptance scenarios

Verify text conversations; multiple tool rounds; structured output re-preparation;
reported invalid calls; repeated provider call IDs under distinct Fabric rounds;
raw Google signed parts; source/result persistence across Fabric restart; and
exactly-once or idempotent tool policy under Fabric's chosen storage contract.
Use the same flow with production configuration and a matching disk cassette.
A cassette is test input and does not serve as an execution checkpoint.
