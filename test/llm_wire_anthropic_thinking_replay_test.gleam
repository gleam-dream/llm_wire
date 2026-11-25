//// Anthropic thinking survives a tool round. Anthropic requires the thinking
//// and redacted thinking blocks of a tool-requesting turn to come back
//// unchanged, signatures included, with the tool results. The turn keeps
//// its content blocks in order as replay data; the next request sends them
//// back exactly, so a tool loop with a thinking level works.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import http_test_helpers
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/message
import llm_wire/testing
import llm_wire/thinking
import tool_fixtures

/// A tool-requesting stream in the shape Anthropic documents for extended
/// thinking with tools: a thinking block whose signature arrives as a
/// `signature_delta` just before its stop, a redacted thinking block that
/// arrives whole, a text block and a tool call.
const stream = [
  "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_01Aq9w938a90dw8q\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-sonnet-4-5\",\"content\":[],\"stop_reason\":null,\"stop_sequence\":null,\"usage\":{\"input_tokens\":412,\"output_tokens\":1}}}\n\n",
  "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"\"}}\n\n",
  "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"The user wants the weather in Paris. \"}}\n\n",
  "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"I should call get_weather.\"}}\n\n",
  "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds2a/3CB4kPC/MQ==\"}}\n\n",
  "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
  "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"EmwKAhgBEgy3va3pzix/LafPsn4aDFIT2Xlxh0L5L8rLVyIwxtE3rAFBa8cr3qpP\"}}\n\n",
  "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n",
  "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
  "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"text_delta\",\"text\":\"Let me check.\"}}\n\n",
  "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":2}\n\n",
  "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":3,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_01T1x1fJ34qAmk2tNTrN7Up6\",\"name\":\"get_weather\",\"input\":{}}}\n\n",
  "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":3,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"city\\\": \\\"Paris\\\"}\"}}\n\n",
  "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":3}\n\n",
  "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":89}}\n\n",
  "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
]

fn config() -> llm_wire.Config {
  anthropic.new("synthetic-key") |> anthropic.config
}

fn first_request() -> llm_wire.Request(String) {
  llm_wire.request("claude-sonnet-4-5", [message.User("Weather in Paris?")])
  |> llm_wire.with_tools([
    tool_fixtures.string_field_tool("get_weather", "city"),
  ])
  |> llm_wire.with_thinking_level(thinking.Medium)
}

fn tool_turn() -> message.AssistantTurn {
  let assert Ok(prepared) = llm_wire.prepare(config(), first_request())
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
    http_test_helpers.run_reply(prepared, testing.events(stream))
  turn
}

fn next_request(turn: message.AssistantTurn) -> llm_wire.Request(String) {
  let assert [call] = turn.calls
  llm_wire.append(first_request(), [
    message.Assistant(turn),
    llm_wire.tool_result(call, "sunny, 21 C"),
  ])
}

/// The `content` of the assistant message in an encoded Anthropic request.
fn assistant_content(body: String) -> List(decode.Dynamic) {
  let decoder =
    decode.field(
      "messages",
      decode.list({
        use role <- decode.field("role", decode.string)
        use content <- decode.optional_field(
          "content",
          [],
          decode.one_of(decode.list(decode.dynamic), [decode.success([])]),
        )
        decode.success(#(role, content))
      }),
      decode.success,
    )
  let assert Ok(messages) = json.parse(body, decoder)
  let assert [#(_, content)] =
    list.filter(messages, fn(entry) { entry.0 == "assistant" })
  content
}

fn field(block: decode.Dynamic, name: String) -> String {
  let assert Ok(value) = decode.run(block, decode.at([name], decode.string))
  value
}

pub fn a_tool_turn_keeps_its_thinking_as_replay_data_test() {
  let turn = tool_turn()
  assert turn.text == "Let me check."
  let assert [message.ToolCall(id: "toolu_01T1x1fJ34qAmk2tNTrN7Up6", ..)] =
    turn.calls
  let assert Some(_) = turn.provider_data
}

/// The next request carries the thinking block with its text and signature,
/// the redacted block with its data, then the text and the call, in the
/// order Anthropic sent them, with a thinking level still set.
pub fn the_next_request_replays_thinking_blocks_unchanged_test() {
  let assert Ok(prepared) =
    llm_wire.prepare(config(), next_request(tool_turn()))
  let assert [thought, redacted, text, call] =
    assistant_content(llm_wire.request_json(prepared))
  assert field(thought, "type") == "thinking"
  assert field(thought, "thinking")
    == "The user wants the weather in Paris. I should call get_weather."
  assert field(thought, "signature")
    == "EqQBCgIYAhIM1gbcDa9GJwZA2b3hGgxBdjrkzLoky3dl1pkiMOYds2a/3CB4kPC/MQ=="
  assert field(redacted, "type") == "redacted_thinking"
  assert field(redacted, "data")
    == "EmwKAhgBEgy3va3pzix/LafPsn4aDFIT2Xlxh0L5L8rLVyIwxtE3rAFBa8cr3qpP"
  assert field(text, "type") == "text"
  assert field(text, "text") == "Let me check."
  assert field(call, "type") == "tool_use"
  assert field(call, "id") == "toolu_01T1x1fJ34qAmk2tNTrN7Up6"
  let assert Ok("Paris") =
    decode.run(call, decode.at(["input", "city"], decode.string))
}

/// A content block of a type this version does not know, as received in its
/// start event: members out of alphabetical order, a number with a trailing
/// zero and nested values, so any re-encoding would show.
const unknown_block =
  "{\"type\":\"future_block\",\"zeta\":1.50,\"alpha\":{\"b\":[1,2],\"a\":\"x\"}}"

/// The documented stream with an unknown block between the thinking and the
/// text. The unknown block's own delta carries nothing replayable.
fn stream_with_unknown_block() -> List(String) {
  let assert [start, thinking_start, d1, d2, sig, thinking_stop, ..rest] =
    stream
  let shift = fn(event: String) {
    event
    |> string.replace("\"index\":1", "\"index\":91")
    |> string.replace("\"index\":2", "\"index\":92")
    |> string.replace("\"index\":3", "\"index\":93")
  }
  list.flatten([
    [start, thinking_start, d1, d2, sig, thinking_stop],
    [
      "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":"
        <> unknown_block
        <> "}\n\n",
      "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"future_delta\",\"x\":1}}\n\n",
      "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n",
    ],
    list.map(rest, shift),
  ])
}

/// An unknown block in a tool turn is sent back byte for byte, in its place,
/// beside the thinking blocks.
pub fn an_unknown_block_is_replayed_unchanged_in_place_test() {
  let assert Ok(prepared) = llm_wire.prepare(config(), first_request())
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
    http_test_helpers.run_reply(
      prepared,
      testing.events(stream_with_unknown_block()),
    )
  let assert Ok(next) = llm_wire.prepare(config(), next_request(turn))
  let body = llm_wire.request_json(next)
  // Byte for byte and in place: after the thinking block's signature,
  // before the redacted thinking block.
  assert string.contains(
    body,
    "MOYds2a/3CB4kPC/MQ==\"},"
      <> unknown_block
      <> ",{\"type\":\"redacted_thinking\"",
  )
  let assert [thought, unknown, redacted, text, call] = assistant_content(body)
  assert field(thought, "type") == "thinking"
  assert field(unknown, "type") == "future_block"
  assert field(redacted, "type") == "redacted_thinking"
  assert field(text, "type") == "text"
  assert field(call, "type") == "tool_use"
}

/// A stored turn keeps its replay data through the turn codec.
pub fn a_stored_turn_replays_the_same_blocks_test() {
  let turn = tool_turn()
  let assert Ok(stored) =
    json.parse(
      json.to_string(message.turn_to_json(turn)),
      message.turn_decoder(),
    )
  assert stored == turn
  let assert Ok(direct) = llm_wire.prepare(config(), next_request(turn))
  let assert Ok(restored) = llm_wire.prepare(config(), next_request(stored))
  assert llm_wire.request_json(direct) == llm_wire.request_json(restored)
}

/// Replay data that disagrees with the turn's text or calls is refused
/// before sending, rather than replaying blocks the caller did not mean.
pub fn replay_data_that_disagrees_with_the_turn_is_refused_test() {
  let turn = message.AssistantTurn(..tool_turn(), text: "Something else.")
  let assert Error(error.InvalidRequest(error.InvalidProviderData(reason))) =
    llm_wire.prepare(config(), next_request(turn))
  assert string.contains(reason, "Anthropic")
}

/// An application-written tool turn has no thinking to replay. Anthropic's
/// adaptive thinking does not require the last assistant turn to start with
/// a thinking block, so the level is sent.
pub fn a_level_is_sent_after_an_application_written_tool_turn_test() {
  let turn =
    message.AssistantTurn(
      provider: None,
      text: "",
      calls: [message.tool_call("call_1", "get_weather", "{}")],
      response_id: None,
      provider_data: None,
    )
  let assert Ok(prepared) = llm_wire.prepare(config(), next_request(turn))
  let assert Ok("adaptive") =
    json.parse(
      llm_wire.request_json(prepared),
      decode.at(["thinking", "type"], decode.string),
    )
}
