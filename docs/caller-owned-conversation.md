# Caller-owned conversation and cassette playback

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
only one admitted request and its transport configuration.

A completed tool response carries `types.AssistantTurn`: provider, text, calls,
response ID, optional provider data, and reported call issues. It contains no
configuration, source conversation, native output codec, callback, or process
reference. `types.AssistantTurnMessage(turn)` embeds that response in a caller's
next request. Provider data belongs to that individual message; Google raw signed
parts stay with their own assistant turn. The caller can append or retain messages
without an implicit history accumulator.

`session.RunToolCalls(turn, usage)` and `StructuredNeedsTools(turn, usage)` expose
the same response data. The caller appends the assistant message and tool results,
then uses ordinary `prepare` or `prepare_structured` again. Structured preparation
requires the desired output codec on each request. Provider adapters return data
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

## Offline cassette playback

Cassette playback substitutes the transport through configuration. The flow uses
the same prepare/run/stream calls and provider parsers as production. A bounded
version-1 JSON file contains ordered expected requests and scripted replies.
Expected requests match method, configured endpoint, effective path and exact
body. Configured headers and their credentials are excluded from fixtures;
request and response bodies are retained verbatim.

A mismatch does not consume the expected exchange. Mismatch, exhaustion, missing
files, malformed data, unknown versions and oversized input fail explicitly.
Playback never falls back to the network. Identical requests may have distinct
responses at different sequence positions. The script owns only test playback
progress, not agent execution progress. File loading, pure parsing/encoding and
script startup remain separate operations. Live recording is a later test-tooling
extension; this slice provides local stored playback.

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
