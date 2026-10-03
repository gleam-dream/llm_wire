//// Configures the built-in OpenAI Responses adapter.
////
//// ```gleam
//// let config =
////   openai.new(api_key)
////   |> openai.with_project("my-project")
////   |> openai.config
//// ```
////
//// The adapter targets `https://api.openai.com/v1`; point it at a
//// compatible server with `llm_wire.with_endpoint`. The key is held in a
//// closure and never prints; `llm_wire.prepare` rejects an empty one with
//// `error.InvalidSetting(error.ApiKey, ..)`.

import gleam/option.{type Option, None, Some}
import gleam/string
import llm_wire
import llm_wire/internal/builtin
import llm_wire/internal/config

pub opaque type Options {
  Options(
    key: fn() -> String,
    organization: Option(String),
    project: Option(String),
  )
}

/// Options for the API key `api_key`, trimmed.
pub fn new(api_key: String) -> Options {
  let key = string.trim(api_key)
  Options(key: fn() { key }, organization: None, project: None)
}

/// Send `OpenAI-Organization`.
pub fn with_organization(options: Options, organization: String) -> Options {
  Options(..options, organization: Some(organization))
}

/// Send `OpenAI-Project`.
pub fn with_project(options: Options, project: String) -> Options {
  Options(..options, project: Some(project))
}

/// The configuration of OpenAI calls, with the default limits and timeouts.
pub fn config(options: Options) -> llm_wire.Config {
  config.new(builtin.openai_adapter(
    options.key,
    options.organization,
    options.project,
  ))
}
