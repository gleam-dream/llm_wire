import gleam/bit_array
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import http_gun/testing as http_testing
import http_test_helpers
import llm_wire/config
import llm_wire/internal/anthropic
import llm_wire/internal/google
import llm_wire/internal/openai
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/provider/anthropic as anthropic_options
import llm_wire/provider/google as google_options
import llm_wire/provider/openai as openai_options
import llm_wire/session
import llm_wire/testing
import llm_wire/types

pub fn complete_provider_interactions_survive_every_byte_split_test() {
  openai_interaction_splits()
  anthropic_interaction_splits()
  google_interaction_splits()
}

fn openai_interaction_splits() {
  let raw =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"item\",\"delta\":\"oé🦊\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}\n\n"
  check_session_fragments(raw, types.OpenAI)
  check_splits(raw, fn(events) {
    let assert Ok(reducer) =
      list.fold(events, Ok(openai.new(types.default_limits())), fn(acc, event) {
        use current <- result.try(acc)
        openai.step(current, event)
        |> result.map(fn(pair) {
          let #(next, _) = pair
          next
        })
      })
    openai.terminal(reducer)
    |> should.equal(
      Some(stream_types.StreamFinished(stream_types.CompletedText("oé🦊"), None)),
    )
  })
}

fn anthropic_interaction_splits() {
  let raw =
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n"
    <> "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
    <> "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"oé🦊\"}}\n\n"
    <> "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
    <> "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n"
    <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
  check_session_fragments(raw, types.Anthropic)
  check_splits(raw, fn(events) {
    let assert Ok(reducer) =
      list.fold(
        events,
        Ok(anthropic.new(types.default_limits())),
        fn(acc, event) {
          use current <- result.try(acc)
          anthropic.step(current, event)
          |> result.map(fn(pair) {
            let #(next, _) = pair
            next
          })
        },
      )
    anthropic.terminal(reducer)
    |> should.equal(
      Some(stream_types.StreamFinished(
        stream_types.CompletedText("oé🦊"),
        Some(types.Usage(1, 1, 2)),
      )),
    )
  })
}

fn google_interaction_splits() {
  let raw =
    "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"oé🦊\"}]}}]}\n\n"
    <> "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[]}}]}\n\n"
  check_session_fragments(raw, types.Google)
  check_splits(raw, fn(events) {
    let assert Ok(reducer) =
      list.fold(events, Ok(google.new(types.default_limits())), fn(acc, event) {
        use current <- result.try(acc)
        google.step(current, event)
        |> result.map(fn(pair) {
          let #(next, _) = pair
          next
        })
      })
    google.terminal(reducer)
    |> should.equal(
      Some(stream_types.StreamFinished(stream_types.CompletedText("oé🦊"), None)),
    )
  })
}

fn check_splits(raw: String, verify: fn(List(sse.ServerSentEvent)) -> Nil) {
  let bits = bit_array.from_string(raw)
  list.each(byte_boundaries(bits), fn(boundary) {
    let #(before, after) = boundary
    let framer = sse.new(types.default_limits())
    let assert Ok(#(framer, left_events)) = sse.feed(framer, before)
    let assert Ok(#(_framer, right_events)) = sse.feed(framer, after)
    verify(list.append(left_events, right_events))
  })
}

fn byte_boundaries(bits: BitArray) -> List(#(BitArray, BitArray)) {
  byte_boundaries_loop(bits, bit_array.byte_size(bits), 0, [])
}

fn byte_boundaries_loop(
  bits: BitArray,
  size: Int,
  position: Int,
  acc: List(#(BitArray, BitArray)),
) -> List(#(BitArray, BitArray)) {
  case position > size {
    True -> list.reverse(acc)
    False -> {
      let assert Ok(before) = bit_array.slice(bits, at: 0, take: position)
      let assert Ok(after) =
        bit_array.slice(bits, at: position, take: size - position)
      byte_boundaries_loop(bits, size, position + 1, [#(before, after), ..acc])
    }
  }
}

// Run every byte as its own HTTP chunk, including each UTF-8 continuation byte
// and the CR/LF split, through the real worker and semantic owner.
fn check_session_fragments(raw: String, provider: types.Provider) -> Nil {
  let assert Ok(key) = types.api_key("synthetic-fragment-key")
  let settings = case provider {
    types.OpenAI -> config.openai(openai_options.options(key))
    types.Anthropic -> config.anthropic(anthropic_options.options(key))
    types.Google -> config.google(google_options.options(key))
    types.Custom(_) -> panic as "built-in fixture required"
  }
  let assert Ok(model) = types.model_id("fixture")
  let assert Ok(call) =
    session.prepare(
      settings,
      types.new_request(model, [types.UserMessage("hello")]),
    )
  let exchange = testing.exchange(call, testing.text("unused"))
  let chunks =
    raw |> string.replace("\n", "\r\n") |> bit_array.from_string |> bytes([])
  let reply =
    http_testing.Respond(
      response.Response(200, [#("content-type", "text/event-stream")], chunks),
      http_testing.Finished([]),
    )
  use client <- http_test_helpers.with_script([
    http_testing.exchange(http_testing.request(exchange), reply),
  ])
  let assert Ok(session.RunText("oé🦊", _)) = session.run(client, call)
  Nil
}

fn bytes(input: BitArray, acc: List(BitArray)) -> List(BitArray) {
  case input {
    <<>> -> list.reverse(acc)
    <<byte, rest:bytes>> -> bytes(rest, [<<byte>>, ..acc])
    _ -> panic as "byte-aligned fixture required"
  }
}
