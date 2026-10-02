//// Holds the options for the built-in OpenAI Responses adapter: the API key
//// and the optional organization and project headers.
////
//// Build `Options` here, then pass them to `config.openai`, which targets
//// `https://api.openai.com/v1`. `config.with_endpoint` points the same adapter
//// at a compatible server.

import gleam/option.{type Option, None, Some}
import llm_wire/types

/// OpenAI settings are built before common session configuration.
pub opaque type Options {
  Options(
    key: types.ApiKey,
    organization: Option(String),
    project: Option(String),
  )
}

pub fn options(key: types.ApiKey) -> Options {
  Options(key, None, None)
}

pub fn with_organization(options: Options, organization: String) -> Options {
  Options(..options, organization: Some(organization))
}

pub fn with_project(options: Options, project: String) -> Options {
  Options(..options, project: Some(project))
}

@internal
pub fn values(
  options: Options,
) -> #(types.ApiKey, Option(String), Option(String)) {
  #(options.key, options.organization, options.project)
}
