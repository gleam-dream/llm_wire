# Caller-owned conversation and HTTP client composition

Accepted on 2026-09-29 by the library owner. This supersedes the continuation and
checkpoint ownership in `docs/continuation-retry.md` and the corresponding tool
continuation section of the parent `oversight/llm-design.md`. The parent design
and Fabric require a subsequent consumer migration; this repository records the
accepted wire boundary here.

## Ownership

LLM Wire prepares one request and normalizes one response. Fabric or another
caller owns conversation history, tool execution, retries, pause/resume,
persistence, and duplicate-effect protection. No continuation handle, checkpoint,
source digest, or state restoration API remains in LLM Wire. Prepared calls own
only one admitted request and its semantic settings; the application supplies the shared HTTP client at execution.

A completed tool response carries `message.AssistantTurn`: provider, text, calls,
response ID and optional provider data; the calls that failed admission are
listed beside it in `llm_wire.NeedsTools(turn, issues, usage)`. It contains no
configuration, source conversation, native output codec, callback, or process
reference. `message.Assistant(turn)` embeds that response in a caller's
next request. Provider data belongs to that individual message; Google raw signed
parts stay with their own assistant turn. The caller can append or retain messages
without an implicit history accumulator.

`llm_wire.NeedsTools(turn, issues, usage)` exposes this response data for plain and
structured requests alike. The caller appends the assistant message and tool
results, then uses ordinary `llm_wire.prepare` again. A structured request keeps
its output codec (`llm_wire.with_output`) on each request. `message.turn_to_json`
and `message.turn_replay_to_json` store a turn; their decoders restore it. Provider adapters return data
with their terminal tool response and interpret it while encoding subsequent
caller-supplied messages; no replay closure registry remains.

## Request validity

Preparation validates each supplied assistant tool batch and its immediately
following results: duplicate, unknown, and missing result identities fail before
transport. Results are normalized into the call order within that turn. IDs may
repeat in different turns. Reported invalid calls remain representable in the
history; outgoing historical messages do not claim current tool admission.

Normalized call metadata and opaque provider data share one metadata byte
budget per assistant turn, on response admission and request preparation.
Provider-specific response data is accepted only for the selected provider.
The Google encoder validates raw parts against the normalized text and calls;
signed parts retain their content and ordering. Unsigned parts use the existing
canonical argument repair. Generic custom data interpretation belongs to the
configured adapter, independent of its public provider identity.

## HTTP client and fixtures (accepted 2026-09-30)

The HTTP Gun migration supersedes this document's original local cassette
implementation, while preserving its caller-owned conversation decision.
HTTP Gun owns generic transport, pooling, HTTP body ownership and byte streaming,
HTTP deadlines/cancellation, scripts, recording and strict playback. LLM Wire owns
provider encoding/reduction, bounded SSE, semantic idle/progress, admission,
structured decoding and conservative semantic retry evidence.

The application starts and shares an `http_gun.Client`, passing it to session
execution. Preparation stays pure and opaque. Live, scripted, recorded and
playback clients use one session path. Current HTTP Gun fixtures preserve binary
chunks and significant headers; only its documented credential metadata names
are excluded. Matching is ordered and non-consuming on mismatch, and never falls
back to a network. Recording performs actual HTTP, with finite capture and an
independent publication result; finalization waits for consumed/closed responses
without draining them. Bodies, queries and unlisted headers are not redacted.

[HTTP Gun migration](http-gun-migration.md) owns the worker/token lifetime,
deadline and error mapping contract. [Validation](http-gun-validation.md) records
the measured adoption evidence. A fixture is test input, not execution state.

## Delivery brief and acceptance

1. Return reusable assistant messages; prove a Google signed tool round can be
   copied into a fresh request without a continuation or the original config.
2. Remove continuation/checkpoint/replay APIs and obsolete tests. Retain response
   admission, round-local result matching, signed content and reported-call repair.
3. Migrate public consumer tests and documentation; record Fabric migration work.
4. Deliver cassette loading and strict playback through the same session path.

Use TDD for new observable behavior; migrate existing assertions to the new public
boundary. Gates: `nix develop -c gleam test`,
`nix develop -c sh test/external_package_boundary.sh`, `nix fmt`, and
`nix flake check`. Compilation checks types; no separate lint/design renderer is
configured. No live provider calls, Fabric source changes, publishing or commits
are part of this slice. Scope questions requiring a new owner decision must be
reported; ordinary naming and implementation choices follow this contract.
