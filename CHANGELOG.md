# Changelog

Release notes begin with the first published version ([ADR 0016](docs/adr/0016-record-unpublished-changes-in-adrs-not-a-changelog.md)). Present behavior lives in the design layer, and the reasons for each change live in the ADRs.

## 0.2.0

### Breaking

- **`message.Usage` gains `thought_tokens: Option(Int)`.** Every construction of `message.Usage(...)` that does not name the new field stops compiling, positional or labelled. Code that only reads fields by label, or matches with `..`, is unaffected. Add `thought_tokens: None` (or `, None` positionally) where you build a usage value, for example in a custom adapter's reducer or in a test that passes one to `testing.with_usage`.
- **`output_tokens` counts every generated token, thoughts included, on every built-in provider.**
  - OpenAI and Anthropic already counted reasoning there.
  - Google's figure now adds `thoughtsTokenCount` to `candidatesTokenCount`, so Gemini output counts grow.
  - `thought_tokens` holds the provider's thought count where it reports one.
  - Totals, budgets and dashboards built on Gemini `output_tokens` change in value, not in meaning: the value is now what the output limit bounds ([ADR 0020](docs/adr/0020-state-a-thinking-level-and-count-thought-tokens.md)).
- **`error.RequestProblem` gains `ThinkingUnsupported(problem: ThinkingProblem)`.** An exhaustive `case` over `RequestProblem` needs an arm for it. `error.describe_prepare_error` describes it.
- **`provider.Request` gains `thinking_level: Option(thinking.Level)`.** Custom adapters that read the request by label are unaffected. One that cannot carry a level should refuse it from `encode` rather than drop it.

### Added

- **`generation.with_thinking_level` and `llm_wire.with_thinking_level` set a `thinking.Level`.** The levels are Minimal, Low, Medium, High, ExtraHigh and Max. Each built-in provider writes the level in its own form:
  - **OpenAI:** `reasoning.effort`.
  - **Google:** `thinkingConfig.thinkingLevel`.
  - **Anthropic:** adaptive thinking with `output_config.effort`.
- **Preparation refuses a level the provider has no value for:** Google `Max` and Anthropic `Minimal`. It also refuses a level on Anthropic while the conversation's last assistant message contains a tool call.
- **Anthropic thinking blocks are read as reasoning progress.** Before this, an Anthropic response with a thinking block failed as a protocol error.

### Who must change

- **Fabric:**
  - Widen its `llm_wire` requirement (`>= 0.1.0 and < 0.2.0`, in the root and in the `app`, `decision` and `writing` consumers) to admit 0.2.0.
  - Add the new field where its tests build `message.Usage(...)`: `test/fabric/llm_test.gleam` and `test/fabric/graph_llm_test.gleam`.
  - Its source reads usage by label and compiles unchanged. Gemini output counts reaching `run.TokenUsage` now include thoughts.
- **dash-crm:**
  - Widen its `llm_wire` requirement (`>= 0.1.1 and < 0.2.0`) to admit 0.2.0.
  - Its source reads usage by label and formats prepare errors with `error.describe_prepare_error`, so it compiles unchanged.
  - Its Gemini output counts now include thoughts.
  - To bound thinking, set `llm_wire.with_thinking_level(thinking.Low)` and leave headroom in `with_max_tokens`. The limit counts thought and visible tokens together, and no level reserves a visible share.
