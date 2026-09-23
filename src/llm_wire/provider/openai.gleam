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
