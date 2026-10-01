import gleam/result
import llm_wire/internal/api
import llm_wire/provider
import llm_wire/provider/anthropic as anthropic_provider
import llm_wire/provider/google as google_provider
import llm_wire/provider/openai as openai_provider
import llm_wire/types

/// Pure provider and semantic execution settings. HTTP policy and client
/// lifetime belong to application startup, independently of preparation.
pub opaque type Config {
  Config(
    provider: provider.Adapter,
    limits: types.Limits,
    deadlines: types.Deadlines,
    tool_call_checks: types.ToolCallChecks,
  )
}

pub fn openai(options: openai_provider.Options) -> Config {
  let #(key, organization, project) = openai_provider.values(options)
  let assert Ok(endpoint) = types.endpoint("https://api.openai.com/v1")
  Config(
    api.openai_adapter(key, endpoint, organization, project),
    types.default_limits(),
    types.default_deadlines(),
    types.RejectInvalidToolCalls,
  )
}

pub fn anthropic(options: anthropic_provider.Options) -> Config {
  let #(key, version) = anthropic_provider.values(options)
  let assert Ok(endpoint) = types.endpoint("https://api.anthropic.com/v1")
  Config(
    api.anthropic_adapter(key, endpoint, version),
    types.default_limits(),
    types.default_deadlines(),
    types.RejectInvalidToolCalls,
  )
}

pub fn google(options: google_provider.Options) -> Config {
  let #(key, api_version) = google_provider.values(options)
  let assert Ok(endpoint) =
    types.endpoint("https://generativelanguage.googleapis.com/v1beta")
  Config(
    api.google_adapter(key, endpoint, api_version),
    types.default_limits(),
    types.default_deadlines(),
    types.RejectInvalidToolCalls,
  )
}

/// Uses an application-defined HTTP/SSE adapter with the same bounded session
/// runtime as the built-in providers.
pub fn from_provider(adapter: provider.Adapter) -> Config {
  Config(
    adapter,
    types.default_limits(),
    types.default_deadlines(),
    types.RejectInvalidToolCalls,
  )
}

pub fn with_endpoint(config: Config, endpoint: types.Endpoint) -> Config {
  Config(..config, provider: provider.with_endpoint(config.provider, endpoint))
}

pub fn with_limits(config: Config, limits: types.Limits) -> Config {
  Config(..config, limits: limits)
}

pub fn with_deadlines(config: Config, deadlines: types.Deadlines) -> Config {
  Config(..config, deadlines: deadlines)
}

/// Select whether invalid tool calls fail the response or remain reported issues.
pub fn with_tool_call_checks(
  config: Config,
  checks: types.ToolCallChecks,
) -> Config {
  Config(..config, tool_call_checks: checks)
}

@internal
pub fn tool_call_checks(config: Config) -> types.ToolCallChecks {
  config.tool_call_checks
}

@internal
pub fn adapter(config: Config) -> provider.Adapter {
  config.provider
}

@internal
pub fn limits(config: Config) -> types.Limits {
  config.limits
}

@internal
pub fn deadlines(config: Config) -> types.Deadlines {
  config.deadlines
}

@internal
pub fn validate(config: Config) -> Result(Nil, types.WireError) {
  let l = config.limits
  let d = config.deadlines
  use Nil <- result.try(types.validate_limits(l))
  use Nil <- result.try(types.validate_deadlines(d))
  Ok(Nil)
}
