//// Final provider events that repeat a long answer on one SSE `data:` line
//// must pass the default limits. OpenAI's `response.output_text.done`,
//// `response.content_part.done`, `response.output_item.done` and
//// `response.completed` carry the whole text; Gemini sends each
//// `functionCall` whole in one chunk. The default line limit therefore equals
//// the event limit, and a smaller configured limit still applies.

import gleam/bit_array
import gleam/http/response
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import http_gun/testing as http_testing
import http_test_helpers
import llm_wire
import llm_wire/error
import llm_wire/google as google_options
import llm_wire/limit
import llm_wire/message
import llm_wire/openai as openai_options
import llm_wire/testing
import llm_wire/tool
import simplifile
import tool_fixtures

const openai_fixture = "test/fixtures/openai-responses-long-text.sse"

const openai_text = "test/fixtures/openai-responses-long-text.txt"

fn key() -> String {
  "synthetic-long-line-key"
}

fn request(tools: List(tool.Tool)) -> llm_wire.Request(String) {
  llm_wire.request("fixture", [message.User("Write a long answer")])
  |> llm_wire.with_tools(tools)
}

// Splits the stream into TCP-segment-sized HTTP chunks, so each long line
// arrives over many reads.
fn chunks(raw: String, size: Int) -> List(BitArray) {
  chunk_loop(bit_array.from_string(raw), size, [])
}

fn chunk_loop(
  bits: BitArray,
  size: Int,
  acc: List(BitArray),
) -> List(BitArray) {
  case bit_array.byte_size(bits) <= size {
    True -> list.reverse([bits, ..acc])
    False -> {
      let assert Ok(head) = bit_array.slice(bits, 0, size)
      let assert Ok(tail) =
        bit_array.slice(bits, size, bit_array.byte_size(bits) - size)
      chunk_loop(tail, size, [head, ..acc])
    }
  }
}

fn run_raw(
  settings: llm_wire.Config,
  tools: List(tool.Tool),
  raw: String,
) -> Result(llm_wire.Outcome(String), llm_wire.Failure) {
  let assert Ok(call) = llm_wire.prepare(settings, request(tools))
  let exchange = testing.exchange(call, testing.text("unused"))
  let reply =
    http_testing.Respond(
      response.Response(
        200,
        [#("content-type", "text/event-stream")],
        chunks(raw, 1400),
      ),
      http_testing.Finished([]),
    )
  use client <- http_test_helpers.with_script([
    http_testing.exchange(http_testing.request(exchange), reply),
  ])
  llm_wire.run(client, call)
}

pub fn default_line_limit_equals_event_limit_test() {
  limit.default(limit.LineBytes)
  |> should.equal(limit.default(limit.EventBytes))
  limit.default(limit.LineBytes) |> should.equal(1_048_576)
}

pub fn openai_reply_over_20_kb_succeeds_with_default_limits_test() {
  let assert Ok(raw) = simplifile.read(openai_fixture)
  let assert Ok(expected) = simplifile.read(openai_text)
  { string.byte_size(expected) > 20_480 } |> should.be_true
  run_raw(openai_options.new(key()) |> openai_options.config, [], raw)
  |> should.equal(
    Ok(llm_wire.Answer(
      output: expected,
      text: expected,
      usage: Some(message.Usage(37, 5012, 5049)),
    )),
  )
}

pub fn configured_line_limit_still_rejects_long_lines_test() {
  let assert Ok(raw) = simplifile.read(openai_fixture)
  let settings =
    openai_options.new(key())
    |> openai_options.config
    |> llm_wire.with_limit(limit.LineBytes, 16_384)
  let assert Error(failure) = run_raw(settings, [], raw)
  let assert error.LimitExceeded(limit.LineBytes, 16_384, observed) =
    failure.error
  { observed > 16_384 } |> should.be_true
}

pub fn google_function_call_over_20_kb_on_one_line_succeeds_test() {
  let lookup = tool_fixtures.string_field_tool("lookup", "query")
  let query = string.repeat("gleam ", 4000)
  let raw =
    "data: {\"responseId\":\"resp_long\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"lookup\",\"id\":\"call_1\",\"args\":{\"query\":\""
    <> query
    <> "\"}}}]}}]}\n\n"
    <> "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}\n\n"
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
    run_raw(google_options.new(key()) |> google_options.config, [lookup], raw)
  let assert [call] = turn.calls
  call.arguments_json |> should.equal("{\"query\":\"" <> query <> "\"}")
}
