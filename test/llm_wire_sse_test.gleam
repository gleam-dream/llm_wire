import gleam/bit_array
import gleam/erlang/atom
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import llm_wire/error
import llm_wire/internal/limits
import llm_wire/internal/sse
import llm_wire/limit

pub fn simple_event_test() {
  let framer = sse.new(limits.default())
  let chunk = <<"data: hello world\n\n":utf8>>
  let assert Ok(#(_framer, events)) = sse.feed(framer, chunk)

  events
  |> should.equal([
    sse.ServerSentEvent(event: None, data: "hello world", id: None, retry: None),
  ])
}

pub fn event_burst_is_bounded_before_materializing_unbounded_events_test() {
  let framer = sse.new(limits.set(limits.default(), limit.QueueCount, 1))
  // The typed limit replaces the old "events_per_chunk_limit" string.
  case sse.feed(framer, <<"data: one\n\ndata: two\n\n":utf8>>) {
    Error(error.LimitExceeded(limit.QueueCount, 1, 2)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn multiline_data_test() {
  let framer = sse.new(limits.default())
  let chunk = <<"data: first line\ndata: second line\n\n":utf8>>
  let assert Ok(#(_framer, events)) = sse.feed(framer, chunk)

  events
  |> should.equal([
    sse.ServerSentEvent(
      event: None,
      data: "first line\nsecond line",
      id: None,
      retry: None,
    ),
  ])
}

pub fn crlf_and_split_crlf_test() {
  let framer = sse.new(limits.default())
  // Chunk 1 ends with \r
  let chunk1 = <<"data: chunked\r":utf8>>
  let assert Ok(#(framer, events1)) = sse.feed(framer, chunk1)
  events1 |> should.equal([])

  // Chunk 2 starts with \n and ends the event
  let chunk2 = <<"\n\r\n":utf8>>
  let assert Ok(#(_framer, events2)) = sse.feed(framer, chunk2)
  events2
  |> should.equal([
    sse.ServerSentEvent(event: None, data: "chunked", id: None, retry: None),
  ])
}

pub fn event_id_and_comment_test() {
  let framer = sse.new(limits.default())
  let payload =
    ": ping comment\nevent: custom\nid: msg_99\nretry: 3000\ndata: payload\n\n"
  let assert Ok(#(_framer, events)) = sse.feed(framer, <<payload:utf8>>)

  events
  |> should.equal([
    sse.ServerSentEvent(
      event: Some("custom"),
      data: "payload",
      id: Some("msg_99"),
      retry: Some(3000),
    ),
  ])
}

pub fn byte_by_byte_split_test() {
  let framer = sse.new(limits.default())
  let raw = "event: message\ndata: {\"text\": \"hello 🚀 world\"}\n\n"
  let bytes = bit_array.from_string(raw)
  let byte_list = split_bytes(bytes)

  let final_events =
    list.fold(byte_list, #(framer, []), fn(acc, single_byte) {
      let #(current_framer, collected) = acc
      let assert Ok(#(next_framer, new_events)) =
        sse.feed(current_framer, single_byte)
      #(next_framer, list.append(collected, new_events))
    })

  final_events.1
  |> should.equal([
    sse.ServerSentEvent(
      event: Some("message"),
      data: "{\"text\": \"hello 🚀 world\"}",
      id: None,
      retry: None,
    ),
  ])
}

pub fn representative_frames_survive_every_single_byte_boundary_test() {
  let cases = [
    #(
      "event: response.output_text.delta\ndata: {\"delta\":\"left 🚀 right\"}\n\n",
      [
        sse.ServerSentEvent(
          event: Some("response.output_text.delta"),
          data: "{\"delta\":\"left 🚀 right\"}",
          id: None,
          retry: None,
        ),
      ],
    ),
    #(
      ": keepalive\r\nevent: usage\r\ndata: first\r\ndata: second\r\nid: m-1\r\nretry: 3000\r\n\r\n",
      [
        sse.ServerSentEvent(
          event: Some("usage"),
          data: "first\nsecond",
          id: Some("m-1"),
          retry: Some(3000),
        ),
      ],
    ),
  ]
  list.each(cases, fn(example) {
    let #(raw, expected) = example
    let bits = bit_array.from_string(raw)
    list.each(split_boundaries(bits), fn(boundary) {
      let #(before, after) = boundary
      let framer = sse.new(limits.default())
      let assert Ok(#(framer, left_events)) = sse.feed(framer, before)
      let assert Ok(#(_framer, right_events)) = sse.feed(framer, after)
      list.append(left_events, right_events) |> should.equal(expected)
    })
  })
}

pub fn split_utf8_multibyte_test() {
  let framer = sse.new(limits.default())
  // The rocket emoji 🚀 is 4 bytes: 0xF0 0x9F 0x99 0x80
  // We feed data: prefix and first 2 bytes of rocket
  let chunk1 = <<"data: hello ":utf8, 0xF0, 0x9F>>
  let assert Ok(#(framer, events1)) = sse.feed(framer, chunk1)
  events1 |> should.equal([])

  // Then remaining 2 bytes and closing newline
  let chunk2 = <<0x9A, 0x80, " world\n\n":utf8>>
  let assert Ok(#(_framer, events2)) = sse.feed(framer, chunk2)
  events2
  |> should.equal([
    sse.ServerSentEvent(
      event: None,
      data: "hello 🚀 world",
      id: None,
      retry: None,
    ),
  ])
}

pub fn chunk_limit_test() {
  let bounds =
    limits.Limits(
      chunk_bytes_limit: 10,
      line_bytes_limit: 100,
      event_bytes_limit: 100,
      request_bytes_limit: 100,
      provider_metadata_bytes_limit: 100,
      queue_count_limit: 10,
      queue_bytes_limit: 100,
      active_blocks_limit: 10,
      text_bytes_per_block_limit: 100,
      total_text_bytes_limit: 100,
      argument_bytes_per_call_limit: 100,
      total_argument_bytes_limit: 100,
      extension_bytes_limit: 100,
      response_body_bytes_limit: 100,
      error_body_bytes_limit: 100,
    )
  let framer = sse.new(bounds)
  let chunk = <<"data: this is longer than ten bytes\n\n":utf8>>
  sse.feed(framer, chunk)
  |> should.be_error
}

pub fn line_limit_test() {
  let bounds =
    limits.Limits(
      chunk_bytes_limit: 100,
      line_bytes_limit: 15,
      event_bytes_limit: 100,
      request_bytes_limit: 100,
      provider_metadata_bytes_limit: 100,
      queue_count_limit: 10,
      queue_bytes_limit: 100,
      active_blocks_limit: 10,
      text_bytes_per_block_limit: 100,
      total_text_bytes_limit: 100,
      argument_bytes_per_call_limit: 100,
      total_argument_bytes_limit: 100,
      extension_bytes_limit: 100,
      response_body_bytes_limit: 100,
      error_body_bytes_limit: 100,
    )
  let framer = sse.new(bounds)
  let chunk = <<
    "data: this_is_a_very_long_line_exceeding_fifteen_bytes\n\n":utf8,
  >>
  sse.feed(framer, chunk)
  |> should.be_error
}

pub fn invalid_utf8_test() {
  let framer = sse.new(limits.default())
  let chunk = <<"data: ":utf8, 0xFF, 0xFE, "\n\n":utf8>>
  sse.feed(framer, chunk)
  |> should.be_error
}

pub fn incomplete_eof_test() {
  let framer = sse.new(limits.default())
  let chunk = <<"data: incomplete":utf8>>
  let assert Ok(#(framer2, [])) = sse.feed(framer, chunk)
  sse.finish(framer2)
  |> should.be_error
}

pub fn finish_uncommitted_event_test() {
  let framer = sse.new(limits.default())
  let chunk = <<"data: final line\n":utf8>>
  let assert Ok(#(framer2, [])) = sse.feed(framer, chunk)
  let assert Ok(events) = sse.finish(framer2)
  events
  |> should.equal([
    sse.ServerSentEvent(event: None, data: "final line", id: None, retry: None),
  ])
}

fn split_bytes(bits: BitArray) -> List(BitArray) {
  case bits {
    <<b:size(8), rest:bits>> -> [<<b:size(8)>>, ..split_bytes(rest)]
    _ -> []
  }
}

fn split_boundaries(bits: BitArray) -> List(#(BitArray, BitArray)) {
  case bits {
    <<byte:size(8), rest:bits>> -> [
      #(<<>>, bits),
      ..list.map(split_boundaries(rest), fn(split) {
        let #(prefix, suffix) = split
        #(bit_array.append(<<byte:size(8)>>, prefix), suffix)
      })
    ]
    _ -> [#(<<>>, bits)]
  }
}

@external(erlang, "erlang", "monotonic_time")
fn monotonic_time(unit: atom.Atom) -> Int

fn feed_in_chunks(
  framer: sse.Framer,
  bits: BitArray,
  size: Int,
  acc: List(sse.ServerSentEvent),
) -> List(sse.ServerSentEvent) {
  case bit_array.byte_size(bits) <= size {
    True -> {
      let assert Ok(#(_framer, events)) = sse.feed(framer, bits)
      list.append(acc, events)
    }
    False -> {
      let assert Ok(head) = bit_array.slice(bits, 0, size)
      let assert Ok(tail) =
        bit_array.slice(bits, size, bit_array.byte_size(bits) - size)
      let assert Ok(#(framer, events)) = sse.feed(framer, head)
      feed_in_chunks(framer, tail, size, list.append(acc, events))
    }
  }
}

// A line under the default 1 MiB limit arriving in TCP-segment-sized chunks is
// scanned once, not once per chunk. The quadratic scan took about 4 s here;
// the linear one takes tens of milliseconds.
pub fn long_line_in_small_chunks_is_scanned_in_linear_time_test() {
  let payload = string.repeat("x", 1_040_000)
  let stream = bit_array.from_string("data: " <> payload <> "\r\n\r\n")
  let millisecond = atom.create("millisecond")
  let started = monotonic_time(millisecond)
  let events = feed_in_chunks(sse.new(limits.default()), stream, 1400, [])
  let elapsed = monotonic_time(millisecond) - started
  events
  |> should.equal([
    sse.ServerSentEvent(event: None, data: payload, id: None, retry: None),
  ])
  { elapsed < 1000 } |> should.be_true
}
