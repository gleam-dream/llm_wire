import gleam/list
import http_test_helpers
import llm_wire
import llm_wire/anthropic as anthropic_options
import llm_wire/error
import llm_wire/message
import llm_wire/openai as openai_options
import llm_wire/testing

/// Read a scripted reply to its end through the streaming interface, keeping
/// the provider extensions that were delivered before the outcome.
fn read(
  settings: llm_wire.Config,
  chunks: List(String),
) -> #(List(String), Result(llm_wire.Outcome(String), llm_wire.Failure)) {
  let assert Ok(call) =
    llm_wire.prepare(
      settings,
      llm_wire.request("fixture", [message.User("hello")]),
    )
  use client <- http_test_helpers.with_script([
    testing.exchange(call, testing.events(chunks)),
  ])
  let assert Ok(stream) = llm_wire.stream(client, call)
  read_loop(stream, [])
}

fn read_loop(
  stream: llm_wire.Stream(String),
  extensions: List(String),
) -> #(List(String), Result(llm_wire.Outcome(String), llm_wire.Failure)) {
  case llm_wire.next(stream) {
    Ok(llm_wire.Progress(message.UnrecognizedEvent(name:, ..))) ->
      read_loop(stream, [name, ..extensions])
    Ok(llm_wire.Progress(_)) -> read_loop(stream, extensions)
    Ok(llm_wire.Done(outcome)) -> #(list.reverse(extensions), outcome)
    Error(_) -> panic as "the stream ended without an outcome"
  }
}

fn anthropic() -> llm_wire.Config {
  anthropic_options.new("synthetic-key") |> anthropic_options.config
}

fn openai() -> llm_wire.Config {
  openai_options.new("synthetic-key") |> openai_options.config
}

const anthropic_start =
  "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n"

const anthropic_end =
  "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n"
  <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"

/// A content block of a type the reducer does not know, with deltas of its
/// own, is skipped. The answer comes from the blocks the reducer knows.
pub fn anthropic_unknown_content_block_is_skipped_test() {
  let #(extensions, outcome) =
    read(anthropic(), [
      anthropic_start,
      "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"future_block\",\"payload\":{\"a\":1}}}\n\n",
      "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"future_delta\",\"payload\":\"x\"}}\n\n",
      "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
      "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
      "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}\n\n",
      "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n",
      anthropic_end,
    ])
  let assert Ok(llm_wire.Answer(text: "hello", ..)) = outcome
  assert extensions == ["content_block_start:future_block"]
}

/// A delta of a type the reducer does not know, inside a block it knows, is
/// skipped. The block keeps its text.
pub fn anthropic_unknown_delta_in_a_known_block_is_skipped_test() {
  let #(extensions, outcome) =
    read(anthropic(), [
      anthropic_start,
      "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
      "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hel\"}}\n\n",
      "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"citations_delta\",\"citation\":{\"type\":\"char_location\"}}}\n\n",
      "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"lo\"}}\n\n",
      "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
      anthropic_end,
    ])
  let assert Ok(llm_wire.Answer(text: "hello", ..)) = outcome
  assert extensions == ["content_block_delta:citations_delta"]
}

/// A known delta type on the wrong kind of block is a contradiction, not a
/// new type, and still fails.
pub fn anthropic_known_delta_on_the_wrong_block_still_fails_test() {
  let #(_, outcome) =
    read(anthropic(), [
      anthropic_start,
      "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
      "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n",
    ])
  let assert Error(llm_wire.Failure(error: error.Protocol(_), ..)) = outcome
}

/// A skipped block follows the block rules: the message cannot end while it
/// is open.
pub fn anthropic_unknown_block_left_open_still_fails_test() {
  let #(_, outcome) =
    read(anthropic(), [
      anthropic_start,
      "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"future_block\"}}\n\n",
      anthropic_end,
    ])
  let assert Error(llm_wire.Failure(error: error.Protocol(_), ..)) = outcome
}

/// An output item of a type the reducer does not know is skipped, including
/// its completion. The answer comes from the items the reducer knows.
pub fn openai_unknown_output_item_is_skipped_test() {
  let #(extensions, outcome) =
    read(openai(), [
      "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"future_1\",\"type\":\"future_call\",\"status\":\"in_progress\"}}\n\n",
      "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"future_1\",\"type\":\"future_call\",\"status\":\"completed\"}}\n\n",
      "event: response.output_item.added\ndata: {\"output_index\":1,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n",
      "event: response.output_text.delta\ndata: {\"output_index\":1,\"item_id\":\"item\",\"delta\":\"hello\"}\n\n",
      "event: response.output_item.done\ndata: {\"output_index\":1,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n",
      "event: response.completed\ndata: {\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}\n\n",
    ])
  let assert Ok(llm_wire.Answer(text: "hello", ..)) = outcome
  assert extensions == ["response.output_item.added:future_call"]
}

/// Completing an item that was never added is still a protocol failure.
pub fn openai_completion_of_an_item_never_added_still_fails_test() {
  let #(_, outcome) =
    read(openai(), [
      "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"ghost\",\"type\":\"message\"}}\n\n",
    ])
  let assert Error(llm_wire.Failure(error: error.Protocol(_), ..)) = outcome
}
