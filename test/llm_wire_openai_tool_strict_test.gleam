//// OpenAI function tools are sent with `"strict": false`, so OpenAI uses the
//// caller's schema as given instead of normalizing it into strict mode when
//// it can. An optional argument stays optional, and the arguments reach the
//// caller exactly as the model wrote them (ADR 0021).

import gleam/option.{type Option}
import gleam/string
import gleeunit/should
import http_test_helpers
import json/blueprint/codec
import llm_wire
import llm_wire/message
import llm_wire/openai
import llm_wire/testing
import llm_wire/tool

fn lookup() -> tool.Tool {
  tool.new("lookup", "Look up a customer", {
    use id <- codec.field(
      "id",
      codec.string(),
      get: fn(a: #(String, Option(String))) { a.0 },
    )
    use region <- codec.optional_field(
      "region",
      codec.string(),
      get: fn(a: #(String, Option(String))) { a.1 },
    )
    codec.success(#(id, region))
  })
}

fn prepared() -> llm_wire.Prepared(String) {
  let assert Ok(prepared) =
    llm_wire.prepare(
      openai.new("test-key") |> openai.config,
      llm_wire.request("gpt-test", [llm_wire.user("find c-1")])
        |> llm_wire.with_tools([lookup()]),
    )
  prepared
}

pub fn an_openai_function_tool_is_sent_non_strict_test() {
  llm_wire.request_json(prepared())
  |> string.contains(
    "{\"type\":\"function\",\"name\":\"lookup\",\"description\":\"Look up a customer\",\"parameters\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"region\":{\"type\":\"string\"}},\"required\":[\"id\"],\"additionalProperties\":false},\"strict\":false}",
  )
  |> should.be_true
}

pub fn tool_arguments_reach_the_caller_as_written_test() {
  let arguments = "{ \"id\": \"c-1\" }"
  let reply =
    testing.events_for(
      message.OpenAI,
      testing.tool_calls("", [testing.tool_call("call_1", "lookup", arguments)]),
    )
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
    http_test_helpers.run_reply(prepared(), reply)
  let assert [call] = turn.calls
  call.arguments_json |> should.equal(arguments)
}
