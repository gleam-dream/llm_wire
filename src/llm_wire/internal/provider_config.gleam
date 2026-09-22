import gleam/option.{type Option}
import llm_wire/types

/// Transport security selected after admitting an endpoint.
pub type TlsMode {
  Plaintext
  VerifySystem
  VerifyCaFile(path: String)
}

/// Provider-specific wire settings retained behind the configured facade.
pub type ProviderConfig {
  OpenAIConfig(
    api_key: types.ApiKey,
    endpoint: types.Endpoint,
    organization: Option(String),
    project: Option(String),
  )
  AnthropicConfig(
    api_key: types.ApiKey,
    endpoint: types.Endpoint,
    version: Option(String),
  )
  GoogleConfig(
    api_key: types.ApiKey,
    endpoint: types.Endpoint,
    api_version: Option(String),
  )
}
