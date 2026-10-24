//// Canonical generation controls; provider request records are derived views.

import gleam/option.{type Option, None, Some}
import llm_wire/internal/adapter
import llm_wire/message

pub opaque type Settings {
  Settings(
    max_tokens: Option(Int),
    temperature: Option(Float),
    top_p: Option(Float),
    stop_sequences: List(String),
    prompt_cache: Option(adapter.PromptCache),
  )
}

pub fn default() -> Settings {
  Settings(None, None, None, [], None)
}

pub fn request_view(
  settings: Settings,
  model: String,
  messages: List(message.Message),
) -> adapter.Request {
  adapter.Request(
    model:,
    messages:,
    max_tokens: settings.max_tokens,
    temperature: settings.temperature,
    top_p: settings.top_p,
    stop_sequences: settings.stop_sequences,
    prompt_cache: settings.prompt_cache,
  )
}

pub fn with_max_tokens(settings: Settings, max: Int) -> Settings {
  Settings(..settings, max_tokens: Some(max))
}

pub fn with_temperature(settings: Settings, temperature: Float) -> Settings {
  Settings(..settings, temperature: Some(temperature))
}

pub fn with_top_p(settings: Settings, top_p: Float) -> Settings {
  Settings(..settings, top_p: Some(top_p))
}

pub fn with_stop_sequences(
  settings: Settings,
  sequences: List(String),
) -> Settings {
  Settings(..settings, stop_sequences: sequences)
}

pub fn with_openai_prompt_cache_key(
  settings: Settings,
  key: String,
) -> Settings {
  Settings(..settings, prompt_cache: Some(adapter.OpenAiPromptCacheKey(key)))
}

pub fn with_google_cached_content(
  settings: Settings,
  name: String,
) -> Settings {
  Settings(..settings, prompt_cache: Some(adapter.GoogleCachedContent(name)))
}
