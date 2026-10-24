//// Opens public streams against a local fake server.

import gleam/int
import http_gun
import llm_wire
import llm_wire/anthropic
import llm_wire/message
import llm_wire/openai
import llm_wire/tool

/// A plain request to `scheme://host:port<base>` for `provider`, configured
/// by `configure`.
pub fn open_stream(
  client: http_gun.Client,
  provider: message.Provider,
  scheme: String,
  host: String,
  port: Int,
  base: String,
  configure: fn(llm_wire.Config) -> llm_wire.Config,
  tools: List(tool.Tool),
) -> Result(llm_wire.Stream(String), llm_wire.Failure) {
  let config = case provider {
    message.OpenAI -> openai.new("test-key") |> openai.config
    message.Anthropic -> anthropic.new("test-key") |> anthropic.config
    _ -> panic as "unsupported test provider"
  }
  let config =
    config
    |> llm_wire.with_endpoint(
      scheme <> "://" <> host <> ":" <> int.to_string(port) <> base,
    )
    |> configure
  let request =
    llm_wire.request("test-model", [llm_wire.user("test request")])
    |> llm_wire.with_tools(tools)
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  llm_wire.stream(client, prepared)
}

pub fn open_openai_stream(
  client: http_gun.Client,
  port: Int,
  configure: fn(llm_wire.Config) -> llm_wire.Config,
  tools: List(tool.Tool),
) -> Result(llm_wire.Stream(String), llm_wire.Failure) {
  open_stream(
    client,
    message.OpenAI,
    "http",
    "127.0.0.1",
    port,
    "/v1",
    configure,
    tools,
  )
}

pub fn open_anthropic_stream(
  client: http_gun.Client,
  port: Int,
  configure: fn(llm_wire.Config) -> llm_wire.Config,
  tools: List(tool.Tool),
) -> Result(llm_wire.Stream(String), llm_wire.Failure) {
  open_stream(
    client,
    message.Anthropic,
    "http",
    "127.0.0.1",
    port,
    "/v1",
    configure,
    tools,
  )
}
