//// Credentials never appear in `string.inspect` output of a public value that
//// holds them: the key, provider options, configs, adapters, specs, prepared
//// calls, open streams and recorded fixture exchanges. Only the explicit
//// `reveal_*` accessors return the key.

import gleam/list
import gleam/string
import gleeunit/should
import http_test_helpers
import json/blueprint/codec
import llm_wire/config
import llm_wire/provider
import llm_wire/provider/anthropic
import llm_wire/provider/google
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/testing
import llm_wire/types
import tool_fixtures

const secret = "sk-secret-redaction-0123456789"

fn key() -> types.ApiKey {
  let assert Ok(key) = types.api_key("  " <> secret <> "  ")
  key
}

fn request() -> types.Request {
  let assert Ok(model) = types.model_id("model-x")
  types.new_request(model, [types.UserMessage("Hi")])
}

fn hidden(value: a) -> Nil {
  string.contains(string.inspect(value), secret) |> should.be_false
}

fn configs() -> List(config.Config) {
  [
    config.openai(
      openai.options(key())
      |> openai.with_organization("org")
      |> openai.with_project("proj"),
    ),
    config.anthropic(anthropic.options(key()) |> anthropic.with_version("v")),
    config.google(google.options(key()) |> google.with_api_version("v1")),
    config.from_provider(custom_adapter()),
  ]
}

fn custom_adapter() -> provider.Adapter {
  let base = config.adapter(testing.config())
  let key = key()
  provider.adapter(
    provider.Spec(
      identity: types.Custom("custom"),
      endpoint: provider.endpoint(base),
      headers: fn() {
        [#("authorization", "Bearer " <> types.reveal_api_key(key))]
      },
      encode: fn(request, tools, format) {
        provider.encode(base, request, tools, format)
      },
      project_tool_schema: provider.blueprint_schema,
      project_output_schema: provider.blueprint_schema,
      new_reducer: fn(limits, tools) {
        provider.new_reducer(base, limits, tools)
      },
    ),
  )
}

pub fn api_key_and_provider_options_do_not_print_the_key_test() {
  hidden(key())
  hidden(openai.options(key()))
  hidden(anthropic.options(key()))
  hidden(google.options(key()))
  types.reveal_api_key(key()) |> should.equal(secret)
}

pub fn configs_and_adapters_do_not_print_the_key_test() {
  list.each(configs(), fn(settings) {
    hidden(settings)
    hidden(config.adapter(settings))
  })
}

pub fn custom_spec_does_not_print_the_key_test() {
  hidden(custom_adapter())
}

pub fn reveal_headers_is_the_only_way_to_read_the_credential_test() {
  let assert [openai_config, anthropic_config, google_config, custom_config] =
    configs()
  let revealed = fn(settings) {
    provider.reveal_headers(config.adapter(settings))
  }
  revealed(openai_config)
  |> list.contains(#("Authorization", "Bearer " <> secret))
  |> should.be_true
  revealed(anthropic_config)
  |> list.contains(#("x-api-key", secret))
  |> should.be_true
  revealed(google_config)
  |> list.contains(#("x-goog-api-key", secret))
  |> should.be_true
  revealed(custom_config)
  |> list.contains(#("authorization", "Bearer " <> secret))
  |> should.be_true
}

pub fn prepared_calls_do_not_print_the_key_test() {
  list.each(configs(), fn(settings) {
    let assert Ok(prepared) = session.prepare(settings, request())
    hidden(prepared)
    let assert Ok(structured) =
      session.prepare_structured(
        settings,
        request(),
        "answer",
        tool_fixtures.one_field("answer", codec.int()),
      )
    hidden(structured)
  })
}

pub fn streams_and_fixture_exchanges_do_not_print_the_key_test() {
  let assert [openai_config, ..] = configs()
  let assert Ok(prepared) = session.prepare(openai_config, request())
  let exchange = testing.exchange(prepared, testing.text("hello"))
  hidden(exchange)
  use client <- http_test_helpers.with_script([exchange])
  let assert Ok(stream) = session.stream(client, prepared)
  hidden(stream)
  let _ = session.close(stream)
  Nil
}
