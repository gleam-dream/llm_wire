//// Configures the built-in Anthropic Messages adapter.
////
//// ```gleam
//// let config = anthropic.new(api_key) |> anthropic.config
//// ```
////
//// The adapter targets `https://api.anthropic.com/v1` and sends
//// `anthropic-version: 2023-06-01` unless `with_version` sets another. The
//// key is held in a closure and never prints.

import gleam/option.{type Option, None, Some}
import gleam/string
import llm_wire
import llm_wire/internal/builtin
import llm_wire/internal/config

pub opaque type Options {
  Options(key: fn() -> String, version: Option(String))
}

/// Options for the API key `api_key`, trimmed.
pub fn new(api_key: String) -> Options {
  let key = string.trim(api_key)
  Options(key: fn() { key }, version: None)
}

/// Send this `anthropic-version` header.
pub fn with_version(options: Options, version: String) -> Options {
  Options(..options, version: Some(version))
}

/// The configuration of Anthropic calls, with the default limits and
/// timeouts.
pub fn config(options: Options) -> llm_wire.Config {
  config.new(builtin.anthropic_adapter(options.key, options.version))
}
