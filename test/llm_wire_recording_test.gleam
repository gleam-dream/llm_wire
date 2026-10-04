import fake_server
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/cassette
import http_gun/config as http_config
import http_gun/testing as http_testing
import http_test_helpers
import json/blueprint/codec
import llm_wire
import llm_wire/error
import llm_wire/message
import llm_wire/testing
import llm_wire_test_tcp as tcp
import simplifile
import tool_fixtures

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "erlang", "system_time")
fn system_time() -> Int

/// `unique_integer` restarts with each VM, so a run that panicked before
/// cleanup would otherwise leave a destination the next run collides with.
fn path() -> String {
  "/private/tmp/llm-wire-http-recording-"
  <> int.to_string(system_time())
  <> "-"
  <> int.to_string(unique_integer())
  <> ".json"
}

fn replies() -> List(testing.Reply) {
  [
    testing.text("hello"),
    testing.tool_calls("Checking", [
      testing.tool_call("c1", "echo", "{\"text\":\"hello\"}"),
    ]),
    testing.text("echoed"),
    testing.text("{\"answer\":42}"),
  ]
}

/// The body chunks of a successful scripted reply (`testing.http_reply` is
/// private now; an `Events` reply is its chunks).
fn reply_chunks(reply: testing.Reply) -> List(#(Int, BitArray)) {
  let chunks = testing.chunks(reply)
  list.map(chunks, fn(chunk) { #(0, bit_array.from_string(chunk)) })
}

fn serve(
  server: fake_server.FakeServer,
  replies: List(testing.Reply),
  seen: process.Subject(Nil),
) -> Nil {
  list.each(replies, fn(reply) {
    let assert Ok(socket) = fake_server.accept_connection(server, 5000)
    let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
    process.send(seen, Nil)
    let _ = fake_server.send_sse_stream(socket, reply_chunks(reply), True)
  })
}

fn local_settings(server: fake_server.FakeServer) -> llm_wire.Config {
  testing.config()
  |> llm_wire.with_endpoint("http://127.0.0.1:" <> int.to_string(server.port))
}

fn answer(text: String) -> Result(llm_wire.Outcome(String), llm_wire.Failure) {
  Ok(llm_wire.Answer(text, text, None))
}

// Exactly this application-owned flow runs live, recorded and strictly offline.
fn workflow(client: http_gun.Client, settings: llm_wire.Config) -> Nil {
  let request = llm_wire.request("synthetic-model", [llm_wire.user("hello")])
  let assert Ok(call) = llm_wire.prepare(settings, request)
  llm_wire.run(client, call) |> should.equal(answer("hello"))
  let request =
    llm_wire.with_tools(request, [
      tool_fixtures.string_field_tool("echo", "text"),
    ])
  let assert Ok(call) = llm_wire.prepare(settings, request)
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) = llm_wire.run(client, call)
  let assert [tool_call] = turn.calls
  let next =
    llm_wire.append(request, [
      message.Assistant(turn),
      llm_wire.tool_result(tool_call, "hello"),
    ])
  let assert Ok(call) = llm_wire.prepare(settings, next)
  llm_wire.run(client, call) |> should.equal(answer("echoed"))
  let assert Ok(call) =
    llm_wire.prepare(
      settings,
      request
        |> llm_wire.with_output(
          "answer",
          tool_fixtures.one_field("answer", codec.int()),
        ),
    )
  let assert Ok(llm_wire.Answer(42, "{\"answer\":42}", _)) =
    llm_wire.run(client, call)
  Nil
}

pub fn live_recording_and_offline_replay_preserve_text_tools_and_structured_test() {
  let assert Ok(server) = fake_server.start()
  let seen = process.new_subject()
  let _ = process.spawn_unlinked(fn() { serve(server, replies(), seen) })
  let destination = path()
  let settings = local_settings(server)
  let assert Ok(recorded) =
    cassette.record(
      http_test_helpers.loopback_config(),
      destination,
      cassette.options() |> cassette.with_max_bytes(1_000_000),
    )
  workflow(recorded.client, settings)
  list.each(replies(), fn(_) {
    let assert Ok(Nil) = process.receive(seen, 1000)
  })
  cassette.finish(recorded.recording, duration.seconds(5))
  |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  fake_server.stop(server)
  let assert Ok(tape) = cassette.load(destination, 1_000_000)
  let assert Ok(client) = http_testing.playback(tape, http_config.default())
  workflow(client, settings)
  http_gun.stop(client)
  let assert Ok(Nil) = simplifile.delete(destination)
}

pub fn concurrent_recording_keeps_admission_order_when_second_finishes_first_test() {
  let assert Ok(server) = fake_server.start()
  let admitted = process.new_subject()
  let ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let release_first = process.new_subject()
      process.send(ready, release_first)
      let assert Ok(first) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = fake_server.read_request_headers(first, 5000)
      process.send(admitted, Nil)
      let assert Ok(second) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = fake_server.read_request_headers(second, 5000)
      send_text(second, "second")
      let assert Ok(Nil) = process.receive(release_first, 5000)
      send_text(first, "first")
    })
  let assert Ok(release_first) = process.receive(ready, 1000)
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(
      http_test_helpers.loopback_config(),
      destination,
      cassette.options(),
    )
  let assert Ok(call) =
    llm_wire.prepare(
      local_settings(server),
      llm_wire.request("fixture", [llm_wire.user("identical")]),
    )
  let assert Ok(first) = llm_wire.stream(recorded.client, call)
  // Observed submission establishes admission order before opening the second.
  let assert Ok(Nil) = process.receive(admitted, 1000)
  llm_wire.run(recorded.client, call) |> should.equal(answer("second"))
  process.send(release_first, Nil)
  llm_wire.collect(first) |> should.equal(answer("first"))
  cassette.finish(recorded.recording, duration.seconds(5))
  |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  fake_server.stop(server)
  let assert Ok(tape) = cassette.load(destination, 1_000_000)
  let assert Ok(client) = http_testing.playback(tape, http_config.default())
  let assert Ok(first) = llm_wire.stream(client, call)
  // First progress proves offline admission before the second call.
  let assert Ok(llm_wire.Progress(message.TextDelta(_, "first"))) =
    llm_wire.next(first)
  llm_wire.run(client, call) |> should.equal(answer("second"))
  llm_wire.collect(first) |> should.equal(answer("first"))
  http_gun.stop(client)
  let assert Ok(Nil) = simplifile.delete(destination)
  Nil
}

fn send_text(socket: tcp.Socket, text: String) -> Nil {
  let _ =
    fake_server.send_sse_stream(socket, reply_chunks(testing.text(text)), True)
  Nil
}

pub fn capture_budget_failure_does_not_change_live_semantic_outcomes_test() {
  let assert Ok(server) = fake_server.start()
  let seen = process.new_subject()
  let _ = process.spawn_unlinked(fn() { serve(server, replies(), seen) })
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(
      http_test_helpers.loopback_config(),
      destination,
      cassette.options() |> cassette.with_max_bytes(128),
    )
  workflow(recorded.client, local_settings(server))
  cassette.finish(recorded.recording, duration.seconds(5))
  |> should.equal(Error(cassette.CaptureFailed(cassette.CaptureLimit)))
  http_gun.stop(recorded.client)
  simplifile.is_file(destination) |> should.equal(Ok(False))
  fake_server.stop(server)
}

pub fn destination_replacement_is_explicit_and_persistence_failure_is_separate_test() {
  let destination = path()
  let assert Ok(Nil) = simplifile.write(destination, "existing")
  let assert Ok(recorded) =
    cassette.record(
      http_test_helpers.loopback_config(),
      destination,
      cassette.options(),
    )
  cassette.finish(recorded.recording, duration.seconds(5))
  |> should.equal(Error(cassette.CaptureFailed(cassette.DestinationExists)))
  simplifile.read(destination) |> should.equal(Ok("existing"))
  http_gun.stop(recorded.client)
  let assert Ok(replacement) =
    cassette.record(
      http_test_helpers.loopback_config(),
      destination,
      cassette.options()
        |> cassette.with_max_bytes(1000)
        |> cassette.replace_existing,
    )
  cassette.finish(replacement.recording, duration.seconds(5))
  |> should.equal(Ok(destination))
  http_gun.stop(replacement.client)
  cassette.load(destination, 1000) |> should.be_ok
  let assert Ok(Nil) = simplifile.delete(destination)
}

pub fn publish_io_failure_keeps_successful_live_result_test() {
  let assert Ok(server) = fake_server.start()
  let seen = process.new_subject()
  let _ = process.spawn_unlinked(fn() { serve(server, replies(), seen) })
  let destination = path()
  let assert Ok(Nil) = simplifile.create_directory(destination)
  let assert Ok(recorded) =
    cassette.record(
      http_test_helpers.loopback_config(),
      destination,
      cassette.options()
        |> cassette.with_max_bytes(1_000_000)
        |> cassette.replace_existing,
    )
  workflow(recorded.client, local_settings(server))
  let assert Error(cassette.CaptureFailed(cassette.IoFailure(
    cassette.PublishFile,
    _,
  ))) = cassette.finish(recorded.recording, duration.seconds(5))
  http_gun.stop(recorded.client)
  let assert Ok(Nil) = simplifile.delete(destination)
  fake_server.stop(server)
}

pub fn finish_wait_never_drains_and_early_cancel_replays_partial_evidence_test() {
  let assert Ok(server) = fake_server.start()
  let closed = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
      let prefix = "event: text\ndata: {\"text\":\"partial\"}\n\n"
      let bytes =
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
        <> int.to_base16(string.byte_size(prefix))
        <> "\r\n"
        <> prefix
        <> "\r\n"
      let assert Ok(Nil) = tcp.send(socket, bit_array.from_string(bytes))
      process.send(closed, tcp.recv(socket, 0, 3000))
      tcp.close(socket)
    })
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(
      http_test_helpers.loopback_config(),
      destination,
      cassette.options(),
    )
  let assert Ok(call) =
    llm_wire.prepare(
      local_settings(server),
      llm_wire.request("synthetic-model", [llm_wire.user("wait")]),
    )
  let assert Ok(stream) = llm_wire.stream(recorded.client, call)
  let assert Ok(llm_wire.Progress(message.TextDelta(_, "partial"))) =
    llm_wire.next(stream)
  cassette.finish(recorded.recording, duration.milliseconds(10))
  |> should.equal(Error(cassette.WaitTimeout))
  llm_wire.close(stream) |> should.equal(llm_wire.Closed)
  cassette.finish(recorded.recording, duration.seconds(5))
  |> should.equal(Ok(destination))
  let assert Ok(Error(_)) = process.receive(closed, 2000)
  http_gun.stop(recorded.client)
  fake_server.stop(server)
  let assert Ok(tape) = cassette.load(destination, 1_000_000)
  let assert Ok(client) = http_testing.playback(tape, http_config.default())
  let assert Error(failure) = llm_wire.run(client, call)
  failure.error |> should.equal(error.Cancelled)
  // Was response bytes and semantic progress observed.
  failure.partial_output |> should.be_true
  failure.sent |> should.equal(llm_wire.MaybeSent)
  http_gun.stop(client)
  let assert Ok(Nil) = simplifile.delete(destination)
}
