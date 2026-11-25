# Replay Anthropic thinking blocks in tool rounds

<a id="adr-0024"></a>

## Decision and alternatives

- Anthropic requires every thinking and redacted thinking block of a tool-requesting assistant turn to come back unchanged, signatures included, with the tool results; a modified block is a 400. The reducer read thinking as reasoning progress and dropped the signatures and redacted data, and the assistant turn had no place for them. ADR 0020 therefore refused a thinking level on Anthropic while a tool round continued, and left a pending ruling on how replay data would carry the blocks. A model that thinks by default sent its turn back without them.
- On 2026-11-25 the repository owner ruled that the blocks travel through conversation replay unchanged. A tool-requesting Anthropic turn that has thinking keeps its content blocks, in the order Anthropic sent them, as the turn's opaque `provider_data`: thinking with its text and signature, redacted thinking with its data, non-empty text, and each tool call by id and name. It uses the format already used for Google's signed parts: a JSON array of block JSON strings. A turn without thinking keeps no data, as before.
- The encoder sends the blocks back in that order. Thinking and text blocks are sent exactly as kept; each tool call is written from the turn's own call, so arguments have one encoding. Before sending, the encoder checks that the data's text and tool calls are exactly the turn's, and refuses with `InvalidProviderData` otherwise, as it does for Google's signed parts.
- The refusal `ThinkingUnsupported(ThinkingInToolRound)` is removed: a provider turn now carries its thinking, and an application-written tool turn has none to carry. The library sends adaptive thinking, which does not require the last assistant turn to start with a thinking block.
- Rejected: storing only the thinking blocks and placing them before the text and calls. Adaptive thinking interleaves thinking between tool calls, and Anthropic rejects blocks that are moved.
- Rejected: public typed thinking blocks on `AssistantTurn`. The blocks are provider-owned and opaque; a typed field would invite edits that Anthropic rejects, and the turn codec already stores `provider_data` unchanged.

## Evidence and limits

- `test/llm_wire_anthropic_thinking_replay_test.gleam` runs a stream in the shape Anthropic documents for extended thinking with tools (thinking deltas, a `signature_delta` before the block stop, a redacted block that arrives whole, text, a tool call) and prepares the next request. Before the change the turn had no replay data and preparation failed with `ThinkingUnsupported(ThinkingInToolRound)`.
- Replay data now includes the thinking text and the turn's text, so it counts against `limit.ProviderMetadataBytes` (1 MiB by default). A response with very long thinking can exceed it and fail with `LimitExceeded(ProviderMetadataBytes)`; the caller can raise the limit.
- No live Anthropic exchange was recorded (the repository has no Anthropic cassette); the shapes follow Anthropic's extended-thinking and streaming documentation as read on 2026-11-25. Whether Anthropic accepts an adaptive-thinking request after an application-written tool turn rests on that documentation.
- An answer turn (`Answer`) still has no turn value, so thinking before a final answer is not replayed; Anthropic allows earlier turns' thinking to be omitted outside a tool round.
