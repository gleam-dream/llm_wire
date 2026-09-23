import gleam/option.{type Option, None, Some}
import llm_wire/types

pub opaque type Options {
  Options(key: types.ApiKey, version: Option(String))
}

pub fn options(key: types.ApiKey) -> Options {
  Options(key, None)
}

pub fn with_version(options: Options, version: String) -> Options {
  Options(..options, version: Some(version))
}

@internal
pub fn values(options: Options) -> #(types.ApiKey, Option(String)) {
  #(options.key, options.version)
}
