//// Reusable generation controls, independent of model, messages and output.
//// Values are immutable and allocate no runtime resources. Setters retain input
//// values; llm_wire.prepare validates them against the selected provider.
//// Applying llm_wire.with_generation replaces every generation control.

import llm_wire/internal/generation as internal

/// Generation controls only; no conversation, tool, credential or output state.
pub type Settings =
  internal.Settings

/// Leave optional controls absent and stop sequences empty. Provider-specific
/// defaults remain with the provider encoder.
pub fn default() -> Settings {
  internal.default()
}

/// Set the maximum output-token count; preparation requires a positive value.
pub fn with_max_tokens(settings: Settings, max: Int) -> Settings {
  internal.with_max_tokens(settings, max)
}

/// Set sampling temperature; preparation accepts values from zero to two.
pub fn with_temperature(settings: Settings, temperature: Float) -> Settings {
  internal.with_temperature(settings, temperature)
}

/// Set nucleus sampling probability; preparation accepts zero through one.
pub fn with_top_p(settings: Settings, top_p: Float) -> Settings {
  internal.with_top_p(settings, top_p)
}

/// Set stop sequences; provider-specific admission remains in preparation.
pub fn with_stop_sequences(
  settings: Settings,
  sequences: List(String),
) -> Settings {
  internal.with_stop_sequences(settings, sequences)
}

/// Set OpenAI's `prompt_cache_key`. Other built-in providers refuse it in
/// `llm_wire.prepare`.
pub fn with_openai_prompt_cache_key(
  settings: Settings,
  key: String,
) -> Settings {
  internal.with_openai_prompt_cache_key(settings, key)
}

/// Set Google's `cachedContent` reference. Other built-in providers refuse it
/// in `llm_wire.prepare`.
pub fn with_google_cached_content(
  settings: Settings,
  name: String,
) -> Settings {
  internal.with_google_cached_content(settings, name)
}
