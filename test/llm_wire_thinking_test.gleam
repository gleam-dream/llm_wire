//// A thinking level reaches each built-in provider in its own form, or
//// preparation refuses it; ADR 0020 tables the values.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/generation
import llm_wire/google
import llm_wire/message
import llm_wire/openai
import llm_wire/provider
import llm_wire/thinking

fn ask() -> llm_wire.Request(String) {
  llm_wire.request("model-x", [message.User("Hello")])
}

fn body(config: llm_wire.Config, request: llm_wire.Request(o)) -> String {
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  llm_wire.request_json(prepared)
}

fn at(text: String, path: List(String)) -> Result(String, Nil) {
  json.parse(text, decode.at(path, decode.string))
  |> result_to_nil
}

fn result_to_nil(result: Result(a, b)) -> Result(a, Nil) {
  case result {
    Ok(value) -> Ok(value)
    Error(_) -> Error(Nil)
  }
}

fn refused(
  config: llm_wire.Config,
  request: llm_wire.Request(o),
) -> error.ThinkingProblem {
  let assert Error(error.InvalidRequest(error.ThinkingUnsupported(problem))) =
    llm_wire.prepare(config, request)
  problem
}

fn answer_codec() -> codec.Codec(String) {
  use answer <- codec.field("answer", codec.string(), get: fn(a) { a })
  codec.success(answer)
}

fn openai_config() -> llm_wire.Config {
  openai.new("key") |> openai.config
}

fn google_config() -> llm_wire.Config {
  google.new("key") |> google.config
}

fn anthropic_config() -> llm_wire.Config {
  anthropic.new("key") |> anthropic.config
}

pub fn openai_writes_each_level_as_reasoning_effort_test() {
  list.each(
    [
      #(thinking.Minimal, "minimal"),
      #(thinking.Low, "low"),
      #(thinking.Medium, "medium"),
      #(thinking.High, "high"),
      #(thinking.ExtraHigh, "xhigh"),
      #(thinking.Max, "max"),
    ],
    fn(case_) {
      let #(level, wire) = case_
      body(openai_config(), ask() |> llm_wire.with_thinking_level(level))
      |> at(["reasoning", "effort"])
      |> should.equal(Ok(wire))
    },
  )
}

pub fn google_writes_each_level_in_the_thinking_config_test() {
  list.each(
    [
      #(thinking.Minimal, "MINIMAL"),
      #(thinking.Low, "LOW"),
      #(thinking.Medium, "MEDIUM"),
      #(thinking.High, "HIGH"),
      #(thinking.ExtraHigh, "XHIGH"),
    ],
    fn(case_) {
      let #(level, wire) = case_
      body(google_config(), ask() |> llm_wire.with_thinking_level(level))
      |> at(["generationConfig", "thinkingConfig", "thinkingLevel"])
      |> should.equal(Ok(wire))
    },
  )
}

pub fn google_keeps_the_level_beside_other_generation_controls_test() {
  let text =
    body(
      google_config(),
      ask()
        |> llm_wire.with_max_tokens(1024)
        |> llm_wire.with_thinking_level(thinking.Low),
    )
  json.parse(
    text,
    decode.at(["generationConfig", "maxOutputTokens"], decode.int),
  )
  |> should.equal(Ok(1024))
  at(text, ["generationConfig", "thinkingConfig", "thinkingLevel"])
  |> should.equal(Ok("LOW"))
}

pub fn anthropic_writes_each_level_as_adaptive_thinking_test() {
  list.each(
    [
      #(thinking.Low, "low"),
      #(thinking.Medium, "medium"),
      #(thinking.High, "high"),
      #(thinking.ExtraHigh, "xhigh"),
      #(thinking.Max, "max"),
    ],
    fn(case_) {
      let #(level, wire) = case_
      let text =
        body(anthropic_config(), ask() |> llm_wire.with_thinking_level(level))
      at(text, ["thinking", "type"]) |> should.equal(Ok("adaptive"))
      at(text, ["output_config", "effort"]) |> should.equal(Ok(wire))
    },
  )
}

pub fn anthropic_merges_the_effort_with_structured_output_test() {
  let text =
    body(
      anthropic_config(),
      ask()
        |> llm_wire.with_output("answer", answer_codec())
        |> llm_wire.with_thinking_level(thinking.Low),
    )
  at(text, ["output_config", "effort"]) |> should.equal(Ok("low"))
  at(text, ["output_config", "format", "type"])
  |> should.equal(Ok("json_schema"))
  // One output_config object, not two members with the same name.
  string.split(text, "\"output_config\"") |> list.length |> should.equal(2)
}

pub fn a_request_without_a_level_carries_no_thinking_field_test() {
  list.each([openai_config(), google_config(), anthropic_config()], fn(config) {
    let text = body(config, ask())
    string.contains(text, "reasoning") |> should.be_false
    string.contains(text, "thinking") |> should.be_false
    string.contains(text, "effort") |> should.be_false
  })
}

pub fn google_refuses_max_test() {
  refused(google_config(), ask() |> llm_wire.with_thinking_level(thinking.Max))
  |> should.equal(error.LevelUnsupported(thinking.Max))
}

pub fn anthropic_refuses_minimal_test() {
  refused(
    anthropic_config(),
    ask() |> llm_wire.with_thinking_level(thinking.Minimal),
  )
  |> should.equal(error.LevelUnsupported(thinking.Minimal))
}

fn tool_round() -> List(message.Message) {
  tool_round_from(message.Anthropic)
}

fn tool_round_from(origin: message.Provider) -> List(message.Message) {
  [
    message.User("Weather in Paris?"),
    message.Assistant(message.AssistantTurn(
      provider: Some(origin),
      text: "",
      calls: [
        message.tool_call("call_1", "get_weather", "{\"city\":\"Paris\"}"),
      ],
      response_id: None,
      provider_data: None,
    )),
    message.ToolResult("call_1", "sunny"),
  ]
}

pub fn anthropic_admits_a_level_after_a_turn_without_calls_test() {
  let messages =
    list.append(tool_round(), [
      message.AssistantParts([message.TextPart("It is sunny.")]),
      message.User("Thanks"),
    ])
  let text =
    body(
      anthropic_config(),
      llm_wire.request("model-x", messages)
        |> llm_wire.with_thinking_level(thinking.Low),
    )
  at(text, ["thinking", "type"]) |> should.equal(Ok("adaptive"))
}

pub fn every_provider_admits_a_level_in_a_tool_round_test() {
  use #(origin, config) <- list.each([
    #(message.OpenAI, openai_config()),
    #(message.Anthropic, anthropic_config()),
  ])
  let request =
    llm_wire.request("model-x", tool_round_from(origin))
    |> llm_wire.with_thinking_level(thinking.Low)
  let assert Ok(_) = llm_wire.prepare(config, request)
  Nil
}

pub fn a_custom_adapter_receives_the_level_test() {
  let config =
    provider.new(
      message.Custom("acme"),
      "https://llm.acme.test/v1",
      fn(request, _, _) {
        case request.thinking_level {
          Some(level) -> Ok(provider.encoded("/x", thinking.name(level)))
          None -> Ok(provider.encoded("/x", "none"))
        }
      },
      fn() { provider.reducer(Nil, fn(s, _) { Ok(#(s, [])) }, fn(_) { None }) },
    )
    |> provider.config
  body(config, ask() |> llm_wire.with_thinking_level(thinking.High))
  |> should.equal("high")
  body(config, ask()) |> should.equal("none")
}

pub fn settings_carry_the_level_and_replacement_clears_it_test() {
  let settings =
    generation.default() |> generation.with_thinking_level(thinking.Medium)
  body(openai_config(), ask() |> llm_wire.with_generation(settings))
  |> at(["reasoning", "effort"])
  |> should.equal(Ok("medium"))
  let cleared =
    ask()
    |> llm_wire.with_thinking_level(thinking.High)
    |> llm_wire.with_generation(generation.default())
  string.contains(body(openai_config(), cleared), "reasoning")
  |> should.be_false
}

pub fn the_refusal_describes_itself_test() {
  error.describe_prepare_error(
    error.InvalidRequest(
      error.ThinkingUnsupported(error.LevelUnsupported(thinking.Max)),
    ),
  )
  |> string.contains("max")
  |> should.be_true
}
