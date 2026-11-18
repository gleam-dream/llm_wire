# State a thinking level and count thought tokens

<a id="adr-0020"></a>

## Decision and alternatives

- **The problem.** A caller could not bound how much a model thinks, and usage hid what thinking cost.
  - dash-crm's agents on gemini-3.8-flash sent `maxOutputTokens` 1024 without `thinkingConfig`.
  - Gemini ended with `MAX_TOKENS`, 979 thought tokens, 41 visible tokens and no text.
  - LLM Wire reported an output-limited outcome with 41 output tokens, because it mapped only Gemini's visible count.
- **The setting.** `generation.with_thinking_level` sets one thinking level: `Minimal`, `Low`, `Medium`, `High`, `ExtraHigh` or `Max`.
  - Each level is a value at least two built-in providers share:
    - `Low`, `Medium`, `High` and `ExtraHigh`: all three.
    - `Minimal`: OpenAI and Google.
    - `Max`: OpenAI and Anthropic.
  - Each built-in adapter writes the level in its provider's own form:

    | Level     | OpenAI `reasoning.effort` | Google `generationConfig.thinkingConfig.thinkingLevel` | Anthropic `thinking: {type: adaptive}` with `output_config.effort` (one `output_config` object with any structured-output `format`) |
    | --------- | ------------------------- | ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
    | Minimal   | `minimal`                 | `MINIMAL`                                              | refused                                                                                                                             |
    | Low       | `low`                     | `LOW`                                                  | `low`                                                                                                                               |
    | Medium    | `medium`                  | `MEDIUM`                                               | `medium`                                                                                                                            |
    | High      | `high`                    | `HIGH`                                                 | `high`                                                                                                                              |
    | ExtraHigh | `xhigh`                   | `XHIGH`                                                | `xhigh`                                                                                                                             |
    | Max       | `max`                     | refused                                                | `max`                                                                                                                               |

  - A request without a level is encoded exactly as before.
  - A custom adapter receives the level as `provider.Request.thinking_level`, and refuses from `encode` what it cannot carry.
- **What preparation refuses.** Preparation fails with `InvalidRequest(ThinkingUnsupported(problem))` in three cases:
  - **Google, `Max`:** Google's levels stop at `XHIGH`.
  - **Anthropic, `Minimal`:** Anthropic's efforts start at `low`.
  - **Anthropic, any level, while the conversation's last assistant message contains a tool call:** this is the tool-round limit below.
- **No model table.** LLM Wire keeps no table of which model takes which level.
  - A model that rejects the value it receives answers with its own status, which reaches the caller as `error.Status`. Examples: a Gemini 2.5 model given a level, gemini-3.8-flash given `MINIMAL` or `XHIGH`, an OpenAI model without reasoning, or an Anthropic model without adaptive thinking.
  - The level is never dropped silently.
  - A table would go stale with every model release, and the provider's answer is authoritative.
- **Usage.** `message.Usage` gains `thought_tokens: Option(Int)`, and `output_tokens` now means every generated token, thoughts included, for every built-in provider.
  - **OpenAI:** `output_tokens` already counted reasoning; `thought_tokens` is `output_tokens_details.reasoning_tokens`.
  - **Anthropic:** `output_tokens` already counted thinking; `thought_tokens` is `output_tokens_details.thinking_tokens`, sent on the final `message_delta`.
  - **Google:** `output_tokens` becomes `candidatesTokenCount` plus `thoughtsTokenCount`, and `thought_tokens` is `thoughtsTokenCount`.
    - Gemini leaves out a count that is zero, so a missing candidate or thought count reads as 0 whenever the prompt and total counts are present.
    - `thought_tokens` stays `None` when the thought count is absent.
  - Each usage report replaces the previous one, as before. The final report holds the counts.
  - `thought_tokens` is `None` wherever a provider reports no thought count.
  - So `output_tokens` is the quantity the output limit bounds on all three providers, and an `OutputLimited` result explains itself without a new field: dash-crm's case reads 1020 output tokens, of which 979 were thought.
- **Anthropic thinking blocks are read as reasoning.** The Anthropic reducer did not register `thinking` or `redacted_thinking` content blocks, so the first `thinking_delta` failed as an unknown block index. Every Anthropic response that thought already failed this way, and a level would make it routine.
  - Thinking text becomes `ReasoningDelta` progress and never joins the answer text.
  - Signature deltas and redacted blocks are accepted and not kept.
- **The break.** The owner ruled the break on 2026-11-18 (one meaning, released as 0.2.0):
  - Every `message.Usage(...)` construction that does not name the new field stops compiling, positional or labelled.
  - Google's output figure changes.
  - `RequestProblem` gains a variant.
  - `provider.Request` gains a field, which breaks only code that constructs it.
- **Rejected alternatives:**
  - Keeping `output_tokens` provider-native beside a new thought count. One field would keep two meanings, and comparing it with the limit would need the provider.
  - Thought tokens in a separate value with `Usage` unchanged. Usage would have two homes, and the usage progress update would need a twin.
  - A separate visible-output budget. No provider has one.
  - A new field on `OutputLimited`. Usage already carries the evidence.
  - Generalising a value only one provider has, such as OpenAI's `none` or Anthropic's `display`.
  - Dropping a level the provider cannot carry.
- **Deferred: a thinking token budget.**
  - Google takes one on Gemini 2.5 (`thinkingBudget`), and Anthropic on models before adaptive thinking (`budget_tokens`, at least 1024 and below `max_tokens`). OpenAI has none.
  - No present caller needs one. dash-crm's gemini-3.8-flash takes only a level, and a budget there gets intermittent 400s.
  - A budget returns when a caller is on a model that takes only a budget. It would arrive as a new setter and a new `provider.Request` field beside `thinking_level`, so adding it breaks nothing. That is why the level has its own field rather than a sum type of level and budget.
  - Gemini's dynamic budget (`-1`) is not offered: leaving the level unset already leaves the model's default.
- **Anthropic tool rounds: a named limit that fails loudly.** Anthropic requires the thinking blocks and signatures of a tool-requesting turn to be sent back with its tool results, and the library does not carry them yet. The owner ruled this a named limit that fails loudly.
  - **What preparation refuses:** a level on Anthropic when the conversation's last assistant message is an assistant turn with a tool call, written by the provider or by the application. Assistant parts carry no calls.
  - **What preparation cannot see:** thinking a model does by default without a level. That conversation reaches Anthropic unchanged, as it did before this change.
  - Carrying the blocks is pending.
- **Anthropic's default output bound stays 1024** when the caller sets no maximum, as an encoding choice. A level that thinks within it can leave little visible output, so a caller setting a level on Anthropic sets a maximum.
- **Anthropic's sampling rules while thinking are its own.** It rejects some `temperature` and `top_p` values with thinking on, and every sampling control on newer API versions. Those rules answer with its status, as other model rules do.
- **OpenAI tool rounds are unchanged.** OpenAI reasoning items are not sent back in tool rounds, as before this change. Whether a reasoning model needs them there was not checked.
- **The pending ruling on richer provider-native generation.** This answers it for one option, with dash-crm as its concrete consumer. The rest of that entry stays open.

## What a caller can guarantee

- **Only the total.** The output limit bounds thought and visible tokens together on every built-in provider.
  - **Documented:** OpenAI's `max_output_tokens` includes reasoning tokens, and Anthropic's `max_tokens` includes thinking.
  - **Observed for Google `generateContent`:** 979 + 41 against 1024, ending `MAX_TOKENS`.
- **A level reserves no visible share.** It steers how much of the limit thinking takes and states no number.
- **A caller that needs room for visible text** chooses a lower level and leaves headroom in the limit. dash-crm will set `Low` with headroom.
- **After the call, usage shows how the limit was spent.**

## Evidence and limits

- Current provider documentation, read on 2026-11-18:
  - **Google:** API reference `generate-content` and the Vertex AI thinking guide. They give the levels per Gemini 3 model and the error for a level on Gemini 2.5.
  - **OpenAI:** reasoning guide, Responses reference and models page. They give effort values including `xhigh` and `max`, and `max_output_tokens` including reasoning.
  - **Anthropic:** extended-thinking and adaptive-thinking guides. They give adaptive thinking with effort from `low` to `max`, thinking counted in output tokens, `usage.output_tokens_details.thinking_tokens` on the final `message_delta`, and the thinking and signature deltas. No Anthropic exchange was recorded live for this change, so the thought count is confirmed by the documentation alone.
- **Google's main thinking page now documents the Interactions API**, not `generateContent`. Its statement that the output limit includes thoughts is confirmed for `generateContent` only by dash-crm's measurement and this repository's live recordings.
- **OpenAI's `response.incomplete` event may carry no usage.** Then `OutputLimited.usage` stays `None`.
- **Per-model level subsets and which models think by default are the provider's to enforce.**
