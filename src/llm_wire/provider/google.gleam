//// Holds the options for the built-in Google Gemini GenerateContent adapter:
//// the API key and an optional `x-goog-api-version` header.
////
//// Build `Options` here, then pass them to `config.google`, which targets
//// `https://generativelanguage.googleapis.com/v1beta`.

import gleam/option.{type Option, None, Some}
import llm_wire/types

pub opaque type Options {
  Options(key: types.ApiKey, api_version: Option(String))
}

pub fn options(key: types.ApiKey) -> Options {
  Options(key, None)
}

pub fn with_api_version(options: Options, version: String) -> Options {
  Options(..options, api_version: Some(version))
}

@internal
pub fn values(options: Options) -> #(types.ApiKey, Option(String)) {
  #(options.key, options.api_version)
}
