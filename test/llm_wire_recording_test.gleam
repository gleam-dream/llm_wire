import fake_server
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import http_gun
import http_gun/cassette
import http_gun/config as http_config
import http_gun/error as http_error
import http_gun/fixture
import http_gun/recording
import http_test_helpers
import json/blueprint/codec
import llm_wire/config
import llm_wire/session
import llm_wire/testing
import llm_wire/types
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
      testing.ScriptedCall("c1", "echo", "{\"text\":\"hello\"}"),
    ]),
    testing.text("echoed"),
    testing.text("{\"answer\":42}"),
  ]
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
    let assert fixture.Respond(response, _) = testing.http_reply(reply)
    let _ =
      fake_server.send_sse_stream(
        socket,
        list.map(response.body, fn(bytes) { #(0, bytes) }),
        True,
      )
  })
}

fn local_settings(server: fake_server.FakeServer) -> config.Config {
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(server.port))
  testing.config() |> config.with_endpoint(endpoint)
}

// Exactly this application-owned flow runs live, recorded and strictly offline.
fn workflow(client: http_gun.Client, settings: config.Config) -> Nil {
  let assert Ok(model) = types.model_id("synthetic-model")
  let request = types.new_request(model, [types.UserMessage("hello")])
  let assert Ok(call) = session.prepare(settings, request)
  session.run(client, call) |> should.equal(Ok(session.RunText("hello", None)))
  let request =
    types.with_tools(request, [tool_fixtures.string_field_tool("echo", "text")])
  let assert Ok(call) = session.prepare(settings, request)
  let assert Ok(session.RunToolCalls(turn, _)) = session.run(client, call)
  let assert [call] = turn.calls
  let next =
    types.Request(
      ..request,
      messages: list.append(request.messages, [
        types.AssistantTurnMessage(turn),
        types.ToolResultMessage(call.id, "hello"),
      ]),
    )
  let assert Ok(call) = session.prepare(settings, next)
  session.run(client, call) |> should.equal(Ok(session.RunText("echoed", None)))
  let assert Ok(call) =
    session.prepare_structured(
      settings,
      request,
      "answer",
      codec.field("answer", codec.int()),
    )
  let assert Ok(session.StructuredValue(42, "{\"answer\":42}", _)) =
    session.run_structured(client, call)
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
      recording.Options(1_000_000, recording.RefuseExisting),
    )
  workflow(recorded.client, settings)
  list.each(replies(), fn(_) {
    let assert Ok(Nil) = process.receive(seen, 1000)
  })
  recording.finish_wait(recorded.recording, 5000)
  |> should.equal(Ok(destination))
  let assert Ok(Nil) = http_gun.stop(recorded.client)
  fake_server.stop(server)
  let assert Ok(tape) = cassette.load(destination, 1_000_000)
  let assert Ok(client) = cassette.playback(tape, http_config.default())
  workflow(client, settings)
  let assert Ok(Nil) = http_gun.stop(client)
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
      recording.default(),
    )
  let assert Ok(model) = types.model_id("fixture")
  let assert Ok(call) =
    session.prepare(
      local_settings(server),
      types.new_request(model, [types.UserMessage("identical")]),
    )
  let assert Ok(first) = session.stream(recorded.client, call)
  // Observed submission establishes admission order before opening the second.
  let assert Ok(Nil) = process.receive(admitted, 1000)
  session.run(recorded.client, call)
  |> should.equal(Ok(session.RunText("second", None)))
  process.send(release_first, Nil)
  session.collect(first) |> should.equal(Ok(session.RunText("first", None)))
  recording.finish_wait(recorded.recording, 5000)
  |> should.equal(Ok(destination))
  let assert Ok(Nil) = http_gun.stop(recorded.client)
  fake_server.stop(server)
  let assert Ok(tape) = cassette.load(destination, 1_000_000)
  let assert Ok(client) = cassette.playback(tape, http_config.default())
  let assert Ok(first) = session.stream(client, call)
  // First progress proves offline admission before the second semantic session.
  let assert Ok(session.NextProgress(types.TextDelta(_, "first"))) =
    session.next(first)
  session.run(client, call) |> should.equal(Ok(session.RunText("second", None)))
  session.collect(first) |> should.equal(Ok(session.RunText("first", None)))
  let assert Ok(Nil) = http_gun.stop(client)
  let assert Ok(Nil) = simplifile.delete(destination)
  Nil
}

fn send_text(socket: tcp.Socket, text: String) -> Nil {
  let assert fixture.Respond(response, _) =
    testing.http_reply(testing.text(text))
  let _ =
    fake_server.send_sse_stream(
      socket,
      list.map(response.body, fn(bytes) { #(0, bytes) }),
      True,
    )
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
      recording.Options(128, recording.RefuseExisting),
    )
  workflow(recorded.client, local_settings(server))
  recording.finish_wait(recorded.recording, 5000)
  |> should.equal(Error(recording.CaptureFailed(recording.CaptureLimit)))
  let assert Ok(Nil) = http_gun.stop(recorded.client)
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
      recording.default(),
    )
  recording.finish_wait(recorded.recording, 5000)
  |> should.equal(Error(recording.CaptureFailed(recording.DestinationExists)))
  simplifile.read(destination) |> should.equal(Ok("existing"))
  let assert Ok(Nil) = http_gun.stop(recorded.client)
  let assert Ok(replacement) =
    cassette.record(
      http_test_helpers.loopback_config(),
      destination,
      recording.Options(1000, recording.ReplaceExisting),
    )
  recording.finish_wait(replacement.recording, 5000)
  |> should.equal(Ok(destination))
  let assert Ok(Nil) = http_gun.stop(replacement.client)
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
      recording.Options(1_000_000, recording.ReplaceExisting),
    )
  workflow(recorded.client, local_settings(server))
  let assert Error(recording.CaptureFailed(recording.IoFailure(
    http_error.PublishFixture,
    _,
  ))) = recording.finish_wait(recorded.recording, 5000)
  let assert Ok(Nil) = http_gun.stop(recorded.client)
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
      recording.default(),
    )
  let assert Ok(model) = types.model_id("synthetic-model")
  let assert Ok(call) =
    session.prepare(
      local_settings(server),
      types.new_request(model, [types.UserMessage("wait")]),
    )
  let assert Ok(stream) = session.stream(recorded.client, call)
  let assert Ok(session.NextProgress(types.TextDelta(_, "partial"))) =
    session.next(stream)
  recording.finish_wait(recorded.recording, 10)
  |> should.equal(Error(recording.WaitTimeout))
  session.close(stream) |> should.equal(Ok(types.ConsumerClosed))
  recording.finish_wait(recorded.recording, 5000)
  |> should.equal(Ok(destination))
  let assert Ok(Error(_)) = process.receive(closed, 2000)
  let assert Ok(Nil) = http_gun.stop(recorded.client)
  fake_server.stop(server)
  let assert Ok(tape) = cassette.load(destination, 1_000_000)
  let assert Ok(client) = cassette.playback(tape, http_config.default())
  let assert Error(session.RunFailure(types.CancelledLocally, evidence)) =
    session.run(client, call)
  evidence.response_bytes_observed |> should.be_true
  evidence.semantic_progress_observed |> should.be_true
  let assert Ok(Nil) = http_gun.stop(client)
  let assert Ok(Nil) = simplifile.delete(destination)
}
