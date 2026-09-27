import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm_wire/internal/api
import llm_wire/internal/transport
import llm_wire/pool
import llm_wire/provider
import llm_wire/provider/anthropic as anthropic_provider
import llm_wire/provider/google as google_provider
import llm_wire/provider/openai as openai_provider
import llm_wire/types

/// Pure provider settings. A pool is attached only when the caller has
/// explicitly started and retained ownership of one.
pub opaque type Config {
  Config(
    provider: provider.Adapter,
    limits: types.Limits,
    deadlines: types.Deadlines,
    pool: Option(pool.Pool),
    ca_cert_file: Option(String),
    connector: Option(transport.Connector),
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
    None,
    None,
    None,
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
    None,
    None,
    None,
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
    None,
    None,
    None,
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
    None,
    None,
    None,
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

/// The caller starts and stops the pool. Config construction allocates nothing.
pub fn with_pool(config: Config, owned_pool: pool.Pool) -> Config {
  Config(..config, pool: Some(owned_pool))
}

/// Trusts the given CA certificate file for local HTTPS endpoints. Preparation
/// rejects an empty path or unsuitable endpoint. The file is read on connect.
pub fn with_ca_cert_file(config: Config, path: String) -> Config {
  Config(..config, ca_cert_file: Some(path))
}

/// Selects how a finished response treats calls to undeclared tools or with
/// invalid arguments. The default, `types.RejectInvalidToolCalls`, fails the
/// response; `types.ReportInvalidToolCalls` returns every call and exposes the
/// failures through `session.tool_call_issues`.
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

/// Replaces the network connection; used by `llm_wire/testing`.
@internal
pub fn with_connector(
  config: Config,
  connector: transport.Connector,
) -> Config {
  Config(..config, connector: Some(connector))
}

@internal
pub fn connector(config: Config) -> Option(transport.Connector) {
  config.connector
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
pub fn pool(config: Config) -> Option(pool.Pool) {
  config.pool
}

@internal
pub fn ca_cert_file(config: Config) -> Option(String) {
  config.ca_cert_file
}

/// Admit public record values too: callers can construct Limits and Deadlines
/// directly, so their smart constructors alone cannot protect this boundary.
@internal
pub fn validate(config: Config) -> Result(Nil, types.WireError) {
  let l = config.limits
  let d = config.deadlines
  use Nil <- result.try(case config.ca_cert_file {
    None -> Ok(Nil)
    Some(path) -> {
      let endpoint = provider.endpoint(config.provider)
      case
        string.trim(path) != "",
        string.starts_with(types.endpoint_to_string(endpoint), "https://")
      {
        False, _ ->
          Error(types.ConfigurationError(
            "CA certificate file path cannot be empty",
          ))
        True, False ->
          Error(types.ConfigurationError(
            "CA certificate file requires an HTTPS endpoint",
          ))
        True, True -> Ok(Nil)
      }
    }
  })
  use Nil <- result.try(types.validate_limits(l))
  use Nil <- result.try(types.validate_deadlines(d))
  Ok(Nil)
}
