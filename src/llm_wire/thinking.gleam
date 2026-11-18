//// How much a model may think before it answers.
////
//// Set a level with `generation.with_thinking_level` or
//// `llm_wire.with_thinking_level`. Each built-in provider writes it in its own
//// form: OpenAI as `reasoning.effort`, Google as
//// `generationConfig.thinkingConfig.thinkingLevel`, Anthropic as adaptive
//// thinking with `output_config.effort`. Each level is a value at least two of
//// them share; `prepare` refuses a level the selected provider has no value
//// for, and a model that does not take the value it receives answers with
//// its own error status.
////
//// On every built-in provider the output limit counts thought and visible
//// tokens together. A level steers how much of that limit thinking takes and
//// reserves no visible share; `message.Usage` shows afterwards how the limit
//// was spent.

/// A thinking level.
pub type Level {
  /// OpenAI `minimal`, Google `MINIMAL`; Anthropic has no such level.
  Minimal
  Low
  Medium
  High
  /// OpenAI, Google and Anthropic `xhigh`, on the models that take it.
  ExtraHigh
  /// OpenAI and Anthropic `max`; Google has no such level.
  Max
}

/// The level's lowercase name: `"minimal"`, `"low"`, `"medium"`, `"high"`,
/// `"xhigh"` or `"max"`.
pub fn name(level: Level) -> String {
  case level {
    Minimal -> "minimal"
    Low -> "low"
    Medium -> "medium"
    High -> "high"
    ExtraHigh -> "xhigh"
    Max -> "max"
  }
}
