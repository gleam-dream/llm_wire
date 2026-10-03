//// LLM-R1: the whole-call, first-token and idle-gap timers, and a `next`
//// that waits for an event instead of polling.

import fake_server
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/time/duration
import gleeunit/should
import http_gun/config as http_config
import http_test_helpers
import llm_wire
import llm_wire/error
import llm_wire/message
import llm_wire/testing
import llm_wire_test_client as client
import tool_fixtures

fn ping() -> String {
  "event: ping\ndata: {\"type\":\"ping\"}\n\n"
}

/// The Anthropic events of a text answer, split so that pings can be
/// placed between the opening and the rest.
fn anthropic_text(text: String) -> #(String, List(String)) {
  let assert testing.Events([start, ..rest]) =
    testing.events_for(message.Anthropic, testing.text(text))
  #(start, rest)
}

fn serve(chunks: List(#(Int, String))) -> fake_server.FakeServer {
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    case fake_server.accept_connection(server, 5000) {
      Ok(socket) -> {
        let _ = fake_server.read_request_headers(socket, 5000)
        let _ =
          fake_server.send_sse_stream(
            socket,
            list.map(chunks, fn(c) { #(c.0, bit_array.from_string(c.1)) }),
            True,
          )
        Nil
      }
      Error(_) -> Nil
    }
  })
  server
}

fn run(
  server: fake_server.FakeServer,
  configure: fn(llm_wire.Config) -> llm_wire.Config,
) -> Result(llm_wire.Outcome(String), llm_wire.Failure) {
  use http <- http_test_helpers.with_client
  let assert Ok(stream) =
    client.open_anthropic_stream(http, server.port, configure, [])
  let outcome = llm_wire.collect(stream)
  fake_server.stop(server)
  outcome
}

fn ms(value: Int) -> llm_wire.Bound {
  llm_wire.After(duration.milliseconds(value))
}

pub fn pings_do_not_count_as_the_first_token_test() {
  let #(start, _) = anthropic_text("late")
  let server = serve([#(0, start), ..list.repeat(#(60, ping()), 8)])
  let assert Error(failure) =
    run(server, llm_wire.with_first_token_timeout(_, ms(200)))
  failure.error |> should.equal(error.DeadlineExceeded(error.FirstToken))
  failure.partial_output |> should.be_false
}

pub fn the_idle_gap_ends_a_stalled_stream_test() {
  let assert testing.Events(events) =
    testing.events_for(message.Anthropic, testing.text("partial"))
  // Opening, block start and one delta, then silence.
  let assert [a, b, c, ..] = events
  let server = serve([#(0, a), #(0, b), #(0, c), #(800, ping())])
  let assert Error(failure) =
    run(server, llm_wire.with_idle_timeout(_, ms(150)))
  failure.error |> should.equal(error.DeadlineExceeded(error.IdleGap))
  failure.partial_output |> should.be_true
  failure.sent |> should.equal(llm_wire.MaybeSent)
}

pub fn pings_reset_the_idle_gap_test() {
  let assert testing.Events([a, b, c, ..rest]) =
    testing.events_for(message.Anthropic, testing.text("steady"))
  let server =
    serve(
      list.flatten([
        [#(0, a), #(0, b), #(0, c)],
        list.repeat(#(60, ping()), 8),
        list.map(rest, fn(event) { #(0, event) }),
      ]),
    )
  let assert Ok(llm_wire.Answer(text: "steady", ..)) =
    run(server, llm_wire.with_idle_timeout(_, ms(200)))
}

pub fn tool_argument_deltas_reset_the_idle_gap_test() {
  let start =
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"usage\":{\"input_tokens\":1}}}\n\n"
  let block =
    "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_1\",\"name\":\"lookup\"}}\n\n"
  let delta = fn(fragment) {
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\""
    <> fragment
    <> "\"}}\n\n"
  }
  let finish = [
    "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
    "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":2}}\n\n",
    "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
  ]
  let fragments = ["{", "\\\"q\\\"", ":", "\\\"x", "y", "z", "\\\"", "}"]
  let server =
    serve(
      list.flatten([
        [#(0, start), #(0, block)],
        list.map(fragments, fn(f) { #(80, delta(f)) }),
        list.map(finish, fn(event) { #(0, event) }),
      ]),
    )
  let lookup = tool_fixtures_lookup()
  use http <- http_test_helpers.with_client
  let assert Ok(stream) =
    client.open_anthropic_stream(
      http,
      server.port,
      llm_wire.with_idle_timeout(_, ms(250)),
      [lookup],
    )
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) = llm_wire.collect(stream)
  fake_server.stop(server)
  let assert [call] = turn.calls
  call.arguments_json |> should.equal("{\"q\":\"xyz\"}")
}

fn tool_fixtures_lookup() {
  tool_fixtures.string_field_tool("lookup", "q")
}

pub fn the_whole_call_bounds_a_stream_that_keeps_pinging_test() {
  let assert testing.Events([a, b, c, ..]) =
    testing.events_for(message.Anthropic, testing.text("forever"))
  let server =
    serve([#(0, a), #(0, b), #(0, c), ..list.repeat(#(50, ping()), 20)])
  let assert Error(failure) =
    run(server, llm_wire.with_call_timeout(_, ms(300)))
  failure.error |> should.equal(error.DeadlineExceeded(error.WholeCall))
}

pub fn next_waits_for_an_event_and_next_within_gives_up_test() {
  let #(start, rest) = anthropic_text("patient")
  let server =
    serve([#(0, start), ..list.map(rest, fn(event) { #(400, event) })])
  use http <- http_test_helpers.with_client
  let assert Ok(stream) =
    client.open_anthropic_stream(http, server.port, fn(c) { c }, [])
  llm_wire.next_within(stream, duration.milliseconds(50))
  |> should.equal(Error(llm_wire.TimedOut))
  // The stream stays readable and `next` blocks until the delta arrives.
  let assert Ok(llm_wire.Progress(message.TextDelta(_, "patient"))) =
    llm_wire.next(stream)
  let assert Ok(llm_wire.Answer(text: "patient", ..)) = llm_wire.collect(stream)
  fake_server.stop(server)
}

pub fn a_short_client_request_timeout_does_not_cut_the_call_test() {
  let #(start, rest) = anthropic_text("slow")
  let server =
    serve([#(0, start), ..list.map(rest, fn(event) { #(150, event) })])
  let settings =
    http_test_helpers.loopback_config()
    |> http_config.with_request_timeout(
      http_config.After(duration.milliseconds(100)),
    )
    |> http_config.with_idle_timeout(
      http_config.After(duration.milliseconds(100)),
    )
  use http <- http_test_helpers.with_settings(settings)
  let assert Ok(stream) =
    client.open_anthropic_stream(http, server.port, fn(c) { c }, [])
  let assert Ok(llm_wire.Answer(text: "slow", ..)) = llm_wire.collect(stream)
  fake_server.stop(server)
}

pub fn close_cancels_a_running_call_test() {
  let #(start, rest) = anthropic_text("never read")
  let server =
    serve([#(0, start), ..list.map(rest, fn(event) { #(500, event) })])
  use http <- http_test_helpers.with_client
  let assert Ok(stream) =
    client.open_anthropic_stream(http, server.port, fn(c) { c }, [])
  llm_wire.close(stream) |> should.equal(llm_wire.Closed)
  llm_wire.close(stream) |> should.equal(llm_wire.AlreadyEnded)
  llm_wire.next(stream) |> should.equal(Error(llm_wire.StreamEnded))
  fake_server.stop(server)
}

/// A usage report is not a first token: a stream that reports usage and then
/// nothing still fails on the first-token timer.
pub fn usage_alone_does_not_end_the_first_token_wait_test() {
  let usage =
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"usage\":{\"input_tokens\":1}}}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{},\"usage\":{\"output_tokens\":1}}\n\n"
  let server = serve([#(0, usage), ..list.repeat(#(60, ping()), 8)])
  let assert Error(failure) =
    run(server, llm_wire.with_first_token_timeout(_, ms(200)))
  failure.error |> should.equal(error.DeadlineExceeded(error.FirstToken))
  failure.partial_output |> should.be_false
}
