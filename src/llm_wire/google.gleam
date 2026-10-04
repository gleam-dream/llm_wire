//// Configures the built-in Google Gemini GenerateContent adapter.
////
//// ```gleam
//// let config = google.new(api_key) |> google.config
//// ```
////
//// The adapter targets `https://generativelanguage.googleapis.com/v1beta`.
//// Gemini's signed parts travel in each assistant turn's `provider_data`
//// and must be replayed unchanged. Structured output is sent as
//// `generationConfig.responseJsonSchema`, which also takes what strict
//// providers refuse: optional fields, `codec.nullable`, number ranges,
//// pairs and `codec.value()`. The key is held in a closure and never
//// prints.

import gleam/option.{type Option, None, Some}
import gleam/string
import llm_wire
import llm_wire/internal/builtin
import llm_wire/internal/config

pub opaque type Options {
  Options(key: fn() -> String, api_version: Option(String))
}

/// Options for the API key `api_key`, trimmed.
pub fn new(api_key: String) -> Options {
  let key = string.trim(api_key)
  Options(key: fn() { key }, api_version: None)
}

/// Send this `x-goog-api-version` header.
pub fn with_api_version(options: Options, version: String) -> Options {
  Options(..options, api_version: Some(version))
}

/// The configuration of Gemini calls, with the default limits and timeouts.
pub fn config(options: Options) -> llm_wire.Config {
  config.new(builtin.google_adapter(options.key, options.api_version))
}
