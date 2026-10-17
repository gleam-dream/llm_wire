//// Public settings and custom-provider compatibility checks, entirely offline.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/generation
import llm_wire/google
import llm_wire/message
import llm_wire/openai
import llm_wire/provider
import llm_wire_consumer as consumer

fn body(config, request) {
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  llm_wire.request_json(prepared)
}

fn base() {
  llm_wire.request("fixture", [llm_wire.user("weather")])
}

fn common() {
  generation.default()
  |> generation.with_max_tokens(128)
  |> generation.with_temperature(0.2)
  |> generation.with_top_p(0.8)
}

fn original_setters() {
  base()
  |> llm_wire.with_max_tokens(128)
  |> llm_wire.with_temperature(0.2)
  |> llm_wire.with_top_p(0.8)
}

// Reads every existing provider.Request label from a separate package.
fn encode(request: provider.Request, tools, output) {
  Ok(provider.encoded(
    "/generate",
    json.to_string(
      json.object([
        #("model", json.string(request.model)),
        #("message_count", json.int(list.length(request.messages))),
        #("max_tokens", optional(request.max_tokens, json.int)),
        #("temperature", optional(request.temperature, json.float)),
        #("top_p", optional(request.top_p, json.float)),
        #("stop_sequences", json.array(request.stop_sequences, json.string)),
        #("has_cache", json.bool(request.prompt_cache != None)),
        #("tool_count", json.int(list.length(tools))),
        #("has_output", json.bool(output != None)),
      ]),
    ),
  ))
}

fn optional(value: Option(a), encode: fn(a) -> json.Json) {
  case value {
    None -> json.null()
    Some(value) -> encode(value)
  }
}

fn custom() {
  provider.new(
    message.Custom("generation-consumer"),
    "https://fixture.invalid",
    encode,
    fn() {
      provider.reducer(Nil, fn(state, _) { Ok(#(state, [])) }, fn(_) { None })
    },
  )
  |> provider.config
}

pub fn main() {
  let openai = openai.new("fixture") |> openai.config
  let anthropic = anthropic.new("fixture") |> anthropic.config
  let google = google.new("fixture") |> google.config
  list.each([openai, anthropic, google, custom()], fn(config) {
    assert body(config, original_setters())
      == body(config, base() |> llm_wire.with_generation(common()))
    assert body(config, base())
      == body(
        config,
        original_setters() |> llm_wire.with_generation(generation.default()),
      )
    assert body(config, original_setters() |> llm_wire.with_max_tokens(256))
      == body(
        config,
        base()
          |> llm_wire.with_generation(common())
          |> llm_wire.with_max_tokens(256),
      )
  })
  assert body(
      openai,
      original_setters() |> llm_wire.with_openai_prompt_cache_key("account"),
    )
    == body(
      openai,
      base()
        |> llm_wire.with_generation(
          common() |> generation.with_openai_prompt_cache_key("account"),
        ),
    )
  assert body(
      google,
      original_setters()
        |> llm_wire.with_google_cached_content("cachedContents/account")
        |> llm_wire.with_stop_sequences(["STOP"]),
    )
    == body(
      google,
      base()
        |> llm_wire.with_generation(
          common()
          |> generation.with_google_cached_content("cachedContents/account")
          |> generation.with_stop_sequences(["STOP"]),
        ),
    )
  assert json.parse(
      body(anthropic, base() |> llm_wire.with_generation(generation.default())),
      decode.at(["max_tokens"], decode.int),
    )
    == Ok(1024)

  let settings =
    common()
    |> generation.with_stop_sequences(["STOP"])
    |> generation.with_openai_prompt_cache_key("account")
  let call =
    message.ToolCall(
      id: "call",
      name: "temperature",
      arguments_json: "{\"city\":\"Paris\"}",
      provider_id: None,
      provider_state: None,
    )
  let turn =
    message.AssistantTurn(
      provider: None,
      text: "checking",
      calls: [call],
      response_id: None,
      provider_data: None,
    )
  let appended = [message.Assistant(turn), llm_wire.tool_result(call, "14")]
  let request =
    base()
    |> llm_wire.with_tools([consumer.temperature_tool()])
    |> llm_wire.with_generation(settings)
    |> llm_wire.with_output("weather", consumer.weather_codec())
    |> llm_wire.append(appended)
  assert llm_wire.model(request) == "fixture"
  assert llm_wire.messages(request) == [llm_wire.user("weather"), ..appended]
  assert list.length(llm_wire.tools(request)) == 1
  let encoded = body(custom(), request)
  assert json.parse(encoded, decode.at(["model"], decode.string))
    == Ok("fixture")
  assert json.parse(encoded, decode.at(["message_count"], decode.int)) == Ok(3)
  assert json.parse(encoded, decode.at(["max_tokens"], decode.int)) == Ok(128)
  assert json.parse(encoded, decode.at(["temperature"], decode.float))
    == Ok(0.2)
  assert json.parse(encoded, decode.at(["top_p"], decode.float)) == Ok(0.8)
  assert json.parse(
      encoded,
      decode.at(["stop_sequences"], decode.list(decode.string)),
    )
    == Ok(["STOP"])
  assert json.parse(encoded, decode.at(["has_cache"], decode.bool)) == Ok(True)
  assert json.parse(encoded, decode.at(["tool_count"], decode.int)) == Ok(1)
  assert json.parse(encoded, decode.at(["has_output"], decode.bool)) == Ok(True)

  // Refusals retain their existing public error taxonomy.
  list.each(
    [
      #(
        openai,
        common() |> generation.with_stop_sequences(["STOP"]),
        error.StopSequencesUnsupported,
      ),
      #(
        google,
        common() |> generation.with_openai_prompt_cache_key("wrong"),
        error.PromptCacheUnsupported,
      ),
      #(
        anthropic,
        common() |> generation.with_google_cached_content("wrong"),
        error.PromptCacheUnsupported,
      ),
      #(
        custom(),
        common() |> generation.with_max_tokens(0),
        error.MaxTokensNotPositive,
      ),
      #(
        custom(),
        common() |> generation.with_temperature(3.0),
        error.TemperatureOutOfRange,
      ),
      #(custom(), common() |> generation.with_top_p(2.0), error.TopPOutOfRange),
      #(
        openai,
        common() |> generation.with_openai_prompt_cache_key(""),
        error.EmptyPromptCache,
      ),
      #(
        google,
        common()
          |> generation.with_stop_sequences(["1", "2", "3", "4", "5", "6"]),
        error.TooManyStopSequences(5),
      ),
    ],
    fn(example) {
      let assert Error(error.InvalidRequest(problem)) =
        llm_wire.prepare(
          example.0,
          base() |> llm_wire.with_generation(example.1),
        )
      assert problem == example.2
    },
  )
  let callbacks = process.new_subject()
  let observed =
    provider.new(
      message.Custom("observed"),
      "https://fixture.invalid",
      fn(request, tools, output) {
        process.send(callbacks, "encode")
        encode(request, tools, output)
      },
      fn() {
        provider.reducer(Nil, fn(state, _) { Ok(#(state, [])) }, fn(_) { None })
      },
    )
    |> provider.with_headers(fn() {
      process.send(callbacks, "headers")
      []
    })
    |> provider.config
  let assert Error(error.InvalidRequest(error.MaxTokensNotPositive)) =
    llm_wire.prepare(
      observed,
      base()
        |> llm_wire.with_generation(
          generation.default() |> generation.with_max_tokens(0),
        ),
    )
  assert process.receive(callbacks, 0) == Error(Nil)
  let assert Ok(_) = llm_wire.prepare(observed, base())
  assert process.receive(callbacks, 1000) == Ok("encode")
  assert process.receive(callbacks, 1000) == Ok("headers")
  Nil
}
