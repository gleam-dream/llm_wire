//// `openai.with_store` sends `store` on every Responses request; without it
//// the field is left out and OpenAI applies its own default (ADR 0021).

import gleam/string
import gleeunit/should
import llm_wire
import llm_wire/openai

fn body(options: openai.Options) -> String {
  let assert Ok(prepared) =
    llm_wire.prepare(
      openai.config(options),
      llm_wire.request("gpt-test", [llm_wire.user("hello")]),
    )
  llm_wire.request_json(prepared)
}

pub fn with_store_false_sends_store_false_test() {
  openai.new("test-key")
  |> openai.with_store(False)
  |> body
  |> string.contains("\"store\":false")
  |> should.be_true
}

pub fn with_store_true_sends_store_true_test() {
  openai.new("test-key")
  |> openai.with_store(True)
  |> body
  |> string.contains("\"store\":true")
  |> should.be_true
}

pub fn without_with_store_the_field_is_left_out_test() {
  openai.new("test-key")
  |> body
  |> string.contains("\"store\"")
  |> should.be_false
}

pub fn store_survives_a_structured_tool_request_test() {
  let assert Ok(prepared) =
    llm_wire.prepare(
      openai.new("test-key") |> openai.with_store(False) |> openai.config,
      llm_wire.request("gpt-test", [llm_wire.user("hello")])
        |> llm_wire.with_max_tokens(64),
    )
  llm_wire.request_json(prepared)
  |> string.contains("\"store\":false")
  |> should.be_true
}
