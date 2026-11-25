//// A completed streamed answer is read to the end of its HTTP body before
//// its outcome is delivered, so an HTTP Gun recording stores the exchange
//// as finished and the connection stays reusable (ADR 0019). A local server
//// sends the provider's terminal event, then the end of the chunked body
//// after a delay, never, or after further bytes.

import fake_server
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import http_gun
import http_gun/cassette
import http_gun/testing as http_testing
import http_test_helpers
import llm_wire
import llm_wire/anthropic
import llm_wire/google
import llm_wire/message
import llm_wire/openai
import llm_wire/testing
import llm_wire_test_tcp as tcp
import simplifile

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

@external(erlang, "erlang", "system_time")
fn system_time() -> Int

fn path() -> String {
  "/tmp/llm-wire-stream-end-"
  <> int.to_string(system_time())
  <> "-"
  <> int.to_string(unique_integer())
  <> ".json"
}

/// Every streaming wire: the three built-in providers and a custom adapter.
fn providers() -> List(message.Provider) {
  [
    message.Google,
    message.OpenAI,
    message.Anthropic,
    message.Custom("scripted"),
  ]
}

fn settings(provider: message.Provider, port: Int) -> llm_wire.Config {
  let endpoint = "http://127.0.0.1:" <> int.to_string(port)
  case provider {
    message.Google -> google.config(google.new("no-key"))
    message.OpenAI -> openai.config(openai.new("no-key"))
    message.Anthropic -> anthropic.config(anthropic.new("no-key"))
    message.Custom(_) -> testing.config()
  }
  |> llm_wire.with_endpoint(endpoint)
}

fn prepared(
  provider: message.Provider,
  port: Int,
  configure: fn(llm_wire.Config) -> llm_wire.Config,
) -> llm_wire.Prepared(String) {
  let assert Ok(call) =
    llm_wire.prepare(
      configure(settings(provider, port)),
      llm_wire.request("m", [llm_wire.user("Oi")]),
    )
  call
}

/// One chunked HTTP/1.1 chunk holding `data`.
fn chunk(data: String) -> BitArray {
  bit_array.from_string(
    int.to_base16(string.byte_size(data)) <> "\r\n" <> data <> "\r\n",
  )
}

/// The end of a chunked body.
const last_chunk = <<"0\r\n\r\n":utf8>>

const head =
  "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"

/// The provider's whole answer `text`, terminal event included, as one
/// string per event.
fn events(provider: message.Provider, text: String) -> List(String) {
  testing.events_for(provider, testing.text(text)) |> testing.chunks
}

/// Reads one request, head and content-length body, from a kept-alive
/// connection.
fn read_request(socket: tcp.Socket) -> Nil {
  let assert Ok(received) = fake_server.read_request_headers(socket, 5000)
  let assert [headers, body] = string.split(received, "\r\n\r\n")
  let assert Ok(length) =
    string.split(string.lowercase(headers), "\r\n")
    |> list.find_map(fn(line) {
      case line {
        "content-length: " <> value -> int.parse(string.trim(value))
        _ -> Error(Nil)
      }
    })
  read_body(socket, length - string.byte_size(body))
}

fn read_body(socket: tcp.Socket, left: Int) -> Nil {
  case left > 0 {
    False -> Nil
    True -> {
      let assert Ok(more) = tcp.recv(socket, 0, 5000)
      read_body(socket, left - bit_array.byte_size(more))
    }
  }
}

/// Sends the head and the answer "Olá", one chunk per event.
fn send_answer(socket: tcp.Socket, provider: message.Provider) -> Nil {
  send_reply(socket, provider, testing.text("Olá"))
}

fn send_reply(
  socket: tcp.Socket,
  provider: message.Provider,
  reply: testing.Reply,
) -> Nil {
  let assert Ok(Nil) = tcp.send(socket, bit_array.from_string(head))
  testing.events_for(provider, reply)
  |> testing.chunks
  |> list.each(fn(event) {
    let assert Ok(Nil) = tcp.send(socket, chunk(event))
  })
}

/// Serves one request: the answer, then each `after_answer` piece after its
/// own delay, then reports to `done` whether the client closed the
/// connection within `hold_ms`.
fn serve(
  server: fake_server.FakeServer,
  provider: message.Provider,
  after_answer: List(#(Int, BitArray)),
  hold_ms: Int,
  done: process.Subject(Bool),
) -> Nil {
  serve_reply(
    server,
    provider,
    testing.text("Olá"),
    after_answer,
    hold_ms,
    done,
  )
}

fn serve_reply(
  server: fake_server.FakeServer,
  provider: message.Provider,
  reply: testing.Reply,
  after_answer: List(#(Int, BitArray)),
  hold_ms: Int,
  done: process.Subject(Bool),
) -> Nil {
  let assert Ok(socket) = fake_server.accept_connection(server, 5000)
  read_request(socket)
  send_reply(socket, provider, reply)
  list.each(after_answer, fn(piece) {
    process.sleep(piece.0)
    let _ = tcp.send(socket, piece.1)
  })
  let closed = case tcp.recv(socket, 0, hold_ms) {
    Error("closed") -> True
    _ -> False
  }
  process.send(done, closed)
  tcp.close(socket)
}

type Run(a) {
  Run(result: a, ending: String, elapsed_ms: Int, client_closed: Bool)
}

/// Starts the local server, runs `call` through a recording client and says
/// how the recorder stored the exchange, how long the call took and whether
/// the client closed the connection.
fn run_recorded(
  provider: message.Provider,
  delay_ms: Int,
  after_answer: List(BitArray),
  configure: fn(llm_wire.Config) -> llm_wire.Config,
  call: fn(http_gun.Client, llm_wire.Prepared(String)) -> a,
) -> Run(a) {
  run_recorded_reply(
    provider,
    testing.text("Olá"),
    delay_ms,
    after_answer,
    configure,
    call,
  )
}

fn run_recorded_reply(
  provider: message.Provider,
  reply: testing.Reply,
  delay_ms: Int,
  after_answer: List(BitArray),
  configure: fn(llm_wire.Config) -> llm_wire.Config,
  call: fn(http_gun.Client, llm_wire.Prepared(String)) -> a,
) -> Run(a) {
  let assert Ok(server) = fake_server.start()
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      // The client closes a cut body within the 1 s bound; a body that
      // ended stays pooled, so the hold only bounds the wait for it.
      serve_reply(
        server,
        provider,
        reply,
        after(delay_ms, after_answer),
        1500,
        done,
      )
    })
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(
      http_test_helpers.loopback_config(),
      destination,
      cassette.options(),
    )
  let started = now_ms()
  let result = call(recorded.client, prepared(provider, server.port, configure))
  let elapsed_ms = now_ms() - started
  let assert Ok(_) = cassette.finish(recorded.recording, duration.seconds(5))
  let client_closed = process.receive(done, 5000) == Ok(True)
  http_gun.stop(recorded.client)
  fake_server.stop(server)
  let assert Ok(tape) = cassette.load(destination, 1_000_000)
  let assert Ok(Nil) = simplifile.delete(destination)
  let assert [exchange] = http_testing.exchanges(tape)
  Run(result:, ending: ending(exchange), elapsed_ms:, client_closed:)
}

/// `pieces` sent together `delay_ms` after the answer.
fn after(delay_ms: Int, pieces: List(BitArray)) -> List(#(Int, BitArray)) {
  case pieces {
    [] -> []
    [first, ..rest] -> [#(delay_ms, first), ..list.map(rest, fn(p) { #(0, p) })]
  }
}

fn ending(exchange: http_testing.Exchange) -> String {
  case http_testing.reply(exchange) {
    http_testing.Respond(_, http_testing.Finished(_)) -> "finished"
    http_testing.Respond(_, http_testing.Abandoned) -> "abandoned"
    http_testing.Respond(_, http_testing.Aborted(_)) -> "aborted"
    http_testing.Reject(_) -> "rejected"
  }
}

fn now_ms() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1000 + nanoseconds / 1_000_000
}

fn unchanged(config: llm_wire.Config) -> llm_wire.Config {
  config
}

fn is_ola(result: Result(llm_wire.Outcome(String), llm_wire.Failure)) -> Bool {
  case result {
    Ok(llm_wire.Answer(text: "Olá", ..)) -> True
    _ -> False
  }
}

pub fn a_delayed_end_of_body_is_recorded_as_finished_test() {
  list.each(providers(), fn(provider) {
    list.each([0, 50, 500], fn(delay_ms) {
      let run =
        run_recorded(provider, delay_ms, [last_chunk], unchanged, llm_wire.run)
      assert #(provider, delay_ms, run.ending, is_ola(run.result))
        == #(provider, delay_ms, "finished", True)
    })
  })
}

pub fn an_end_that_never_comes_returns_the_answer_at_the_bound_test() {
  list.each(providers(), fn(provider) {
    let run = run_recorded(provider, 0, [], unchanged, llm_wire.run)
    assert is_ola(run.result)
    // The bound is 1 s after the terminal event.
    assert run.elapsed_ms >= 900
    assert run.elapsed_ms < 3000
    assert run.client_closed
    assert run.ending != "finished"
  })
}

pub fn the_whole_call_deadline_caps_the_read_to_the_end_test() {
  let configure = fn(config) {
    llm_wire.with_call_timeout(config, duration.milliseconds(400))
  }
  // HTTP Gun refuses to publish a recording interrupted by a deadline, so
  // this call runs on a plain client.
  let assert Ok(server) = fake_server.start()
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      serve(server, message.Google, [], 3000, done)
    })
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  let started = now_ms()
  assert is_ola(llm_wire.run(
    client,
    prepared(message.Google, server.port, configure),
  ))
  let elapsed = now_ms() - started
  // The read waited for the body until the 400 ms deadline, not 1 s.
  assert elapsed >= 300
  assert elapsed < 900
  assert process.receive(done, 5000) == Ok(True)
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn bytes_after_the_terminal_never_change_the_outcome_test() {
  list.each(providers(), fn(provider) {
    let trailing = [
      chunk("data: [DONE]\n\n"),
      chunk("data: {not json at all\n\n"),
      chunk(string.concat(events(provider, "Other"))),
      <<"6\r\n":utf8, 0xff, 0xfe, "\n\n\n\n\r\n":utf8>>,
      last_chunk,
    ]
    let run = run_recorded(provider, 20, trailing, unchanged, llm_wire.run)
    assert #(provider, run.ending, is_ola(run.result))
      == #(provider, "finished", True)
  })
}

pub fn trailing_bytes_past_the_byte_bound_close_the_body_test() {
  let piece = chunk(": " <> string.repeat("x", 16_000) <> "\n\n")
  // Five pieces, 200 ms after the answer, exceed 64 KiB; the body never ends.
  let run =
    run_recorded(
      message.Google,
      200,
      list.repeat(piece, 5),
      unchanged,
      llm_wire.run,
    )
  assert is_ola(run.result)
  // The read waited for the trailing bytes and stopped at the byte bound.
  assert run.elapsed_ms >= 150
  assert run.elapsed_ms < 900
  assert run.client_closed
  assert run.ending != "finished"
}

pub fn progress_arrives_before_the_end_of_the_body_test() {
  let run =
    run_recorded(message.Google, 500, [last_chunk], unchanged, fn(client, call) {
      let assert Ok(stream) = llm_wire.stream(client, call)
      let started = now_ms()
      let assert Ok(llm_wire.Progress(message.TextDelta(_, "Olá"))) =
        llm_wire.next(stream)
      let progress_ms = now_ms() - started
      let assert Ok(llm_wire.Done(outcome)) = llm_wire.next(stream)
      #(progress_ms, now_ms() - started, outcome)
    })
  let #(progress_ms, done_ms, outcome) = run.result
  // The outcome waited for the end of the body, 500 ms after the progress.
  assert done_ms - progress_ms >= 300
  assert is_ola(outcome)
  assert run.ending == "finished"
}

pub fn close_during_the_read_hands_the_answer_to_a_waiting_reader_test() {
  let run =
    run_recorded(message.Google, 0, [], unchanged, fn(client, call) {
      let assert Ok(stream) = llm_wire.stream(client, call)
      let assert Ok(llm_wire.Progress(_)) = llm_wire.next(stream)
      let collected = process.new_subject()
      let _ =
        process.spawn(fn() { process.send(collected, llm_wire.collect(stream)) })
      // The reader waits for the outcome while the body is outstanding.
      let waiting = process.receive(collected, 100) == Error(Nil)
      let started = now_ms()
      let closed = llm_wire.close(stream)
      let assert Ok(outcome) = process.receive(collected, 1000)
      #(waiting, closed, outcome, now_ms() - started, llm_wire.next(stream))
    })
  let #(waiting, closed, outcome, close_ms, later) = run.result
  assert waiting
  assert closed == llm_wire.AlreadyEnded
  assert is_ola(outcome)
  assert close_ms < 500
  assert later == Error(llm_wire.StreamEnded)
  assert run.client_closed
}

pub fn creator_death_during_the_read_releases_the_body_test() {
  let assert Ok(server) = fake_server.start()
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      serve(server, message.Google, [], 3000, done)
    })
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  let call = prepared(message.Google, server.port, unchanged)
  let progressed = process.new_subject()
  let creator =
    process.spawn_unlinked(fn() {
      let assert Ok(stream) = llm_wire.stream(client, call)
      let assert Ok(llm_wire.Progress(_)) = llm_wire.next(stream)
      process.send(progressed, Nil)
      process.sleep(10_000)
    })
  let assert Ok(Nil) = process.receive(progressed, 2000)
  // The body is still being read when the creator dies.
  assert process.receive(done, 100) == Error(Nil)
  process.kill(creator)
  // Its death, not the 1 s bound, releases the body.
  assert process.receive(done, 500) == Ok(True)
  http_gun.stop(client)
  fake_server.stop(server)
}

/// A creator that ends normally hands the latched outcome to a reader already
/// waiting; one that ends abnormally ends the owner through their link.
pub fn creator_exit_during_the_read_hands_the_answer_to_a_waiting_reader_test() {
  let assert Ok(server) = fake_server.start()
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      serve(server, message.Google, [], 3000, done)
    })
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  let call = prepared(message.Google, server.port, unchanged)
  let started = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(stream) = llm_wire.stream(client, call)
      let assert Ok(llm_wire.Progress(_)) = llm_wire.next(stream)
      let exit = process.new_subject()
      process.send(started, #(stream, exit))
      let assert Ok(Nil) = process.receive(exit, 5000)
    })
  let assert Ok(#(stream, exit)) = process.receive(started, 2000)
  let collected = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(collected, llm_wire.collect(stream))
    })
  // The reader waits for the outcome while the body is outstanding.
  assert process.receive(collected, 100) == Error(Nil)
  process.send(exit, Nil)
  let assert Ok(outcome) = process.receive(collected, 500)
  assert is_ola(outcome)
  assert process.receive(done, 500) == Ok(True)
  http_gun.stop(client)
  fake_server.stop(server)
}

/// Serves two requests on one connection, each answer's body ending after
/// a delay.
fn serve_twice(server: fake_server.FakeServer, done: process.Subject(Nil)) {
  let assert Ok(socket) = fake_server.accept_connection(server, 5000)
  list.each([1, 2], fn(_) {
    read_request(socket)
    send_answer(socket, message.Google)
    process.sleep(50)
    let assert Ok(Nil) = tcp.send(socket, last_chunk)
  })
  process.send(done, Nil)
  process.sleep(200)
  tcp.close(socket)
}

pub fn the_connection_is_reused_after_a_delayed_end_test() {
  let assert Ok(server) = fake_server.start()
  let done = process.new_subject()
  let _ = process.spawn_unlinked(fn() { serve_twice(server, done) })
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  // A second connection is never accepted: a short whole-call timeout
  // turns a lost connection into a quick failure rather than a hang.
  let call =
    prepared(message.Google, server.port, fn(config) {
      llm_wire.with_call_timeout(config, duration.milliseconds(3000))
    })
  assert is_ola(llm_wire.run(client, call))
  assert is_ola(llm_wire.run(client, call))
  assert process.receive(done, 3000) == Ok(Nil)
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn a_recording_is_complete_when_the_call_returns_test() {
  let assert Ok(server) = fake_server.start()
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      serve(server, message.Google, [#(100, last_chunk)], 1000, done)
    })
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(
      http_test_helpers.loopback_config(),
      destination,
      cassette.options(),
    )
  let answer =
    llm_wire.run(
      recorded.client,
      prepared(message.Google, server.port, unchanged),
    )
  assert is_ola(answer)
  // No wait: nothing the call started is still in flight.
  assert cassette.finish(recorded.recording, duration.milliseconds(0))
    == Ok(destination)
  http_gun.stop(recorded.client)
  fake_server.stop(server)
  let assert Ok(tape) = cassette.load(destination, 1_000_000)
  let assert Ok(Nil) = simplifile.delete(destination)
  let assert [exchange] = http_testing.exchanges(tape)
  assert ending(exchange) == "finished"
}

pub fn trailing_bytes_dripped_slowly_stop_at_the_bound_test() {
  let assert Ok(server) = fake_server.start()
  let done = process.new_subject()
  // A comment every 300 ms, forever within the byte bound.
  let drip = list.repeat(#(300, chunk(": still here\n\n")), 20)
  let _ =
    process.spawn_unlinked(fn() {
      serve(server, message.Google, drip, 100, done)
    })
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  let call =
    prepared(message.Google, server.port, fn(config) {
      llm_wire.with_call_timeout(config, duration.seconds(60))
    })
  let started = now_ms()
  assert is_ola(llm_wire.run(client, call))
  let elapsed = now_ms() - started
  assert elapsed >= 900
  assert elapsed < 3000
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn malformed_bytes_after_the_terminal_in_its_chunk_never_change_the_outcome_test() {
  list.each(providers(), fn(provider) {
    let assert Ok(server) = fake_server.start()
    let done = process.new_subject()
    let _ =
      process.spawn_unlinked(fn() {
        let assert Ok(socket) = fake_server.accept_connection(server, 5000)
        read_request(socket)
        let assert Ok(Nil) = tcp.send(socket, bit_array.from_string(head))
        // The whole answer and invalid UTF-8 after it, in one chunk.
        let answer =
          bit_array.from_string(string.concat(events(provider, "Olá")))
        let data = <<answer:bits, "data: ":utf8, 0xff, 0xfe, "\n\n":utf8>>
        let size = int.to_base16(bit_array.byte_size(data))
        let assert Ok(Nil) =
          tcp.send(socket, <<size:utf8, "\r\n":utf8, data:bits, "\r\n":utf8>>)
        let assert Ok(Nil) = tcp.send(socket, last_chunk)
        process.send(done, Nil)
        process.sleep(500)
        tcp.close(socket)
      })
    let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
    let result =
      llm_wire.run(client, prepared(provider, server.port, unchanged))
    assert #(provider, is_ola(result)) == #(provider, True)
    let assert Ok(Nil) = process.receive(done, 2000)
    http_gun.stop(client)
    fake_server.stop(server)
  })
}

pub fn outcomes_that_are_failures_also_wait_for_the_end_of_the_body_test() {
  // A tool batch that admission refuses (the request declares no tools)
  // and a provider-reported content filter are both decided at the
  // terminal and read to the end.
  let refused =
    testing.tool_calls("", [testing.tool_call("c1", "unknown", "{}")])
  let filtered = testing.content_filtered("Ol")
  list.each([#("refused", refused), #("filtered", filtered)], fn(named) {
    let #(name, reply) = named
    let run =
      run_recorded_reply(
        message.Google,
        reply,
        300,
        [last_chunk],
        unchanged,
        llm_wire.run,
      )
    let failed = case run.result {
      Error(_) -> True
      Ok(_) -> False
    }
    assert #(name, failed, run.ending, run.elapsed_ms >= 250)
      == #(name, True, "finished", True)
  })
}
