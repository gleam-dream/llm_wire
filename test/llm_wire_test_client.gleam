import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm_wire/internal/api
import llm_wire/internal/client
import llm_wire/internal/owner
import llm_wire/internal/provider_config
import llm_wire/types

pub fn open_openai_stream(
  host: String,
  port: Int,
  path: String,
  api_key: types.ApiKey,
  limits: types.Limits,
  deadlines: types.Deadlines,
  tools: List(types.ToolDefinition),
  _body: String,
) -> Result(owner.Stream, types.WireError) {
  open_stream(
    types.OpenAI,
    host,
    port,
    path,
    api_key,
    limits,
    deadlines,
    tools,
    None,
  )
}

pub fn open_anthropic_stream(
  host: String,
  port: Int,
  path: String,
  api_key: types.ApiKey,
  limits: types.Limits,
  deadlines: types.Deadlines,
  tools: List(types.ToolDefinition),
  _body: String,
) -> Result(owner.Stream, types.WireError) {
  open_stream(
    types.Anthropic,
    host,
    port,
    path,
    api_key,
    limits,
    deadlines,
    tools,
    None,
  )
}

pub fn open_openai_stream_with_tls_mode(
  host: String,
  port: Int,
  path: String,
  api_key: types.ApiKey,
  limits: types.Limits,
  deadlines: types.Deadlines,
  tools: List(types.ToolDefinition),
  _body: String,
  tls_mode: provider_config.TlsMode,
) -> Result(owner.Stream, types.WireError) {
  open_stream(
    types.OpenAI,
    host,
    port,
    path,
    api_key,
    limits,
    deadlines,
    tools,
    Some(tls_mode),
  )
}

fn open_stream(
  provider: types.Provider,
  host: String,
  port: Int,
  path: String,
  api_key: types.ApiKey,
  limits: types.Limits,
  deadlines: types.Deadlines,
  tools: List(types.ToolDefinition),
  tls_override: Option(provider_config.TlsMode),
) -> Result(owner.Stream, types.WireError) {
  let suffix = case provider {
    types.OpenAI -> "/responses"
    types.Anthropic -> "/messages"
    types.Google -> ""
  }
  let base_path = string.drop_end(path, string.byte_size(suffix))
  let scheme = case tls_override {
    Some(provider_config.VerifySystem)
    | Some(provider_config.VerifyCaFile(_)) -> "https"
    Some(provider_config.Plaintext) | None -> "http"
  }
  let endpoint_text =
    scheme <> "://" <> host <> ":" <> int.to_string(port) <> base_path
  use endpoint <- result.try(types.endpoint(endpoint_text))
  let config = case provider {
    types.OpenAI -> provider_config.OpenAIConfig(api_key, endpoint, None, None)
    types.Anthropic -> provider_config.AnthropicConfig(api_key, endpoint, None)
    types.Google -> panic as "Google test client is unsupported"
  }
  use model <- result.try(types.model_id("test-model"))
  let request =
    types.new_request(model, [types.UserMessage("test request")])
    |> types.with_tools(tools)
  use prepared <- result.try(api.prepare(config, request, limits))
  client.open_prepared_stream(prepared, limits, deadlines, tls_override)
}
