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
import llm_wire/config
import llm_wire/provider/google as google_options
import llm_wire/provider/openai as openai_options
import llm_wire/session
import llm_wire/testing
import llm_wire/types
import simplifile
import tool_fixtures

const openai_fixture = "test/fixtures/openai-responses-long-text.sse"

const openai_text = "test/fixtures/openai-responses-long-text.txt"

fn key() -> types.ApiKey {
  let assert Ok(key) = types.api_key("synthetic-long-line-key")
  key
}

fn request(tools: List(types.ToolDefinition)) -> types.Request {
  let assert Ok(model) = types.model_id("fixture")
  types.new_request(model, [types.UserMessage("Write a long answer")])
  |> types.with_tools(tools)
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
  settings: config.Config,
  tools: List(types.ToolDefinition),
  raw: String,
) -> Result(session.RunResult, session.RunFailure) {
  let assert Ok(call) = session.prepare(settings, request(tools))
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
  session.run(client, call)
}

pub fn default_line_limit_equals_event_limit_test() {
  let limits = types.default_limits()
  limits.line_bytes_limit |> should.equal(limits.event_bytes_limit)
  limits.line_bytes_limit |> should.equal(1_048_576)
}

pub fn openai_reply_over_20_kb_succeeds_with_default_limits_test() {
  let assert Ok(raw) = simplifile.read(openai_fixture)
  let assert Ok(expected) = simplifile.read(openai_text)
  { string.byte_size(expected) > 20_480 } |> should.be_true
  run_raw(config.openai(openai_options.options(key())), [], raw)
  |> should.equal(
    Ok(session.RunText(expected, Some(types.Usage(37, 5012, 5049)))),
  )
}

pub fn configured_line_limit_still_rejects_long_lines_test() {
  let assert Ok(raw) = simplifile.read(openai_fixture)
  let limits = types.Limits(..types.default_limits(), line_bytes_limit: 16_384)
  let settings =
    config.openai(openai_options.options(key())) |> config.with_limits(limits)
  let assert Error(session.RunFailure(error, _)) = run_raw(settings, [], raw)
  let assert types.ResourceLimitExceeded("line_bytes_limit", 16_384, observed) =
    error
  { observed > 16_384 } |> should.be_true
}

pub fn google_function_call_over_20_kb_on_one_line_succeeds_test() {
  let tool = tool_fixtures.string_field_tool("lookup", "query")
  let query = string.repeat("gleam ", 4000)
  let raw =
    "data: {\"responseId\":\"resp_long\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"lookup\",\"id\":\"call_1\",\"args\":{\"query\":\""
    <> query
    <> "\"}}}]}}]}\n\n"
    <> "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}\n\n"
  let assert Ok(session.RunToolCalls(turn, _)) =
    run_raw(config.google(google_options.options(key())), [tool], raw)
  let assert [call] = turn.calls
  call.arguments_json |> should.equal("{\"query\":\"" <> query <> "\"}")
}
