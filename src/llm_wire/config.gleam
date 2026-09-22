import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm_wire/internal/provider_config
import llm_wire/pool
import llm_wire/types

/// Pure provider settings. A pool is attached only when the caller has
/// explicitly started and retained ownership of one.
pub opaque type Config {
  Config(
    provider: provider_config.ProviderConfig,
    limits: types.Limits,
    deadlines: types.Deadlines,
    pool: Option(pool.Pool),
    ca_cert_file: Option(String),
  )
}

pub fn openai(key: types.ApiKey) -> Config {
  let assert Ok(endpoint) = types.endpoint("https://api.openai.com/v1")
  Config(
    provider_config.OpenAIConfig(key, endpoint, None, None),
    types.default_limits(),
    types.default_deadlines(),
    None,
    None,
  )
}

pub fn anthropic(key: types.ApiKey) -> Config {
  let assert Ok(endpoint) = types.endpoint("https://api.anthropic.com/v1")
  Config(
    provider_config.AnthropicConfig(key, endpoint, None),
    types.default_limits(),
    types.default_deadlines(),
    None,
    None,
  )
}

pub fn google(key: types.ApiKey) -> Config {
  let assert Ok(endpoint) =
    types.endpoint("https://generativelanguage.googleapis.com/v1beta")
  Config(
    provider_config.GoogleConfig(key, endpoint, None),
    types.default_limits(),
    types.default_deadlines(),
    None,
    None,
  )
}

pub fn with_endpoint(config: Config, endpoint: types.Endpoint) -> Config {
  let provider = case config.provider {
    provider_config.OpenAIConfig(..) as current ->
      provider_config.OpenAIConfig(..current, endpoint: endpoint)
    provider_config.AnthropicConfig(..) as current ->
      provider_config.AnthropicConfig(..current, endpoint: endpoint)
    provider_config.GoogleConfig(..) as current ->
      provider_config.GoogleConfig(..current, endpoint: endpoint)
  }
  Config(..config, provider: provider)
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

pub fn with_openai_organization(
  config: Config,
  organization: String,
) -> Result(Config, types.WireError) {
  case config.provider {
    provider_config.OpenAIConfig(..) as current ->
      Ok(
        Config(
          ..config,
          provider: provider_config.OpenAIConfig(
            ..current,
            organization: Some(organization),
          ),
        ),
      )
    _ ->
      Error(types.ConfigurationError(
        "OpenAI organization requires an OpenAI config",
      ))
  }
}

pub fn with_openai_project(
  config: Config,
  project: String,
) -> Result(Config, types.WireError) {
  case config.provider {
    provider_config.OpenAIConfig(..) as current ->
      Ok(
        Config(
          ..config,
          provider: provider_config.OpenAIConfig(
            ..current,
            project: Some(project),
          ),
        ),
      )
    _ ->
      Error(types.ConfigurationError("OpenAI project requires an OpenAI config"))
  }
}

pub fn with_anthropic_version(
  config: Config,
  version: String,
) -> Result(Config, types.WireError) {
  case config.provider {
    provider_config.AnthropicConfig(..) as current ->
      Ok(
        Config(
          ..config,
          provider: provider_config.AnthropicConfig(
            ..current,
            version: Some(version),
          ),
        ),
      )
    _ ->
      Error(types.ConfigurationError(
        "Anthropic version requires an Anthropic config",
      ))
  }
}

pub fn with_google_api_version(
  config: Config,
  version: String,
) -> Result(Config, types.WireError) {
  case config.provider {
    provider_config.GoogleConfig(..) as current ->
      Ok(
        Config(
          ..config,
          provider: provider_config.GoogleConfig(
            ..current,
            api_version: Some(version),
          ),
        ),
      )
    _ ->
      Error(types.ConfigurationError(
        "Google API version requires a Google config",
      ))
  }
}

@internal
pub fn provider_config(config: Config) -> provider_config.ProviderConfig {
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
      let endpoint = case config.provider {
        provider_config.OpenAIConfig(endpoint: endpoint, ..)
        | provider_config.AnthropicConfig(endpoint: endpoint, ..)
        | provider_config.GoogleConfig(endpoint: endpoint, ..) -> endpoint
      }
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
