import gleam/option
import http_test_helpers
import llm_wire
import llm_wire/anthropic as anthropic_options
import llm_wire/error
import llm_wire/message
import llm_wire/testing

fn prepared() -> llm_wire.Prepared(String) {
  let settings =
    anthropic_options.new("synthetic-stop-key") |> anthropic_options.config
  let assert Ok(call) =
    llm_wire.prepare(
      settings,
      llm_wire.request("fixture", [message.User("count to three")])
        |> llm_wire.with_stop_sequences(["END"]),
    )
  call
}

fn text_block(text: String) -> String {
  "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
  <> "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\""
  <> text
  <> "\"}}\n\n"
  <> "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
}

const message_start =
  "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude\",\"usage\":{\"input_tokens\":4,\"output_tokens\":1}}}\n\n"

const stop_sequence_end =
  "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"stop_sequence\",\"stop_sequence\":\"END\"},\"usage\":{\"output_tokens\":3}}\n\n"
  <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

/// The model wrote one of the caller's stop sequences. Anthropic ends the
/// message normally with `stop_reason: "stop_sequence"`; the text before the
/// sequence is the answer.
pub fn anthropic_stop_sequence_is_an_answer_test() {
  let call = prepared()
  let reply =
    testing.events([
      message_start,
      text_block("one two three "),
      stop_sequence_end,
    ])
  let assert Ok(llm_wire.Answer(output:, text:, usage:)) =
    http_test_helpers.run_reply(call, reply)
  assert output == "one two three "
  assert text == "one two three "
  let assert option.Some(message.Usage(input_tokens: 4, output_tokens: 3, ..)) =
    usage
}

/// A tool call needs the `tool_use` stop reason. A stop-sequence stop that
/// leaves a tool call behind stays a failure, as an `end_turn` stop does.
pub fn anthropic_stop_sequence_with_a_tool_call_is_not_an_answer_test() {
  let call = prepared()
  let tool_block =
    "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"lookup\",\"input\":{}}}\n\n"
    <> "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n"
    <> "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
  let reply = testing.events([message_start, tool_block, stop_sequence_end])
  let assert Error(failure) = http_test_helpers.run_reply(call, reply)
  let assert error.Provider(code: option.Some("stop_sequence"), ..) =
    failure.error
}
