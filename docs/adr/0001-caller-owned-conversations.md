# Keep conversations and durable execution with the caller

<a id="adr-0001"></a>

## Decision and alternatives

- The owner assigned history, continuation, tool execution and persistence to Fabric or another caller on 2026-09-29. LLM Wire returns an assistant turn; callers append the turn and exact tool results, then prepare an ordinary request.
- The rejected unpublished design retained a provider-bound continuation, source identity and checkpoint codec in the wire library. Those capabilities confused reusable response data with agent state and duplicated the durable host's authority.
- Provider-required replay data remains message-local. Removing continuation ownership does not permit removing Google's signed content or round-local result validation; immutable prepared values still provide no single-use guarantee.

## Evidence

- The implementation is [bbde1d9](https://github.com/gleam-dream/llm_wire/commit/bbde1d927675e3fe55dcbc5f456a9bcb6fe24107). The recorded owner decision and delivery constraints are in the [original ownership document](https://github.com/gleam-dream/llm_wire/blob/4726271d1671f48fe63222bc2133af1aacfe60e9/docs/caller-owned-conversation.md).
- The current [message model](https://github.com/gleam-dream/llm_wire/blob/4726271d1671f48fe63222bc2133af1aacfe60e9/src/llm_wire/message.gleam) and [admission](https://github.com/gleam-dream/llm_wire/blob/4726271d1671f48fe63222bc2133af1aacfe60e9/src/llm_wire/internal/api.gleam) implement codecs, provider binding and local exact result coverage. Retained turn, message, integration and consumer fixtures govern those observable laws.
- This record consolidates continuation-retry, caller-owned-conversation and fabric-migration documents. Their unpublished intermediate APIs are historical evidence; their current ownership and compatibility requirements are in the native layer.
