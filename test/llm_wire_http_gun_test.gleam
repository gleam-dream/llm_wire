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
import http_gun/config as http_config
import http_gun/error as http_error
import http_test_helpers
import llm_wire
import llm_wire/error
import llm_wire/message
import llm_wire/openai
import llm_wire/provider
import llm_wire_test_tcp as tcp

fn ms(value: Int) -> llm_wire.Bound {
  llm_wire.After(duration.milliseconds(value))
}

fn hello() -> llm_wire.Request(String) {
  llm_wire.request("fixture", [llm_wire.user("hi")])
}

pub fn reducer_exception_releases_http_and_preserves_shared_client_test() {
  let assert Ok(server) = fake_server.start()
  let closed = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
      let prefix = "event: text\ndata: fail\n\n"
      let assert Ok(Nil) =
        tcp.send(
          socket,
          bit_array.from_string(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
            <> int.to_base16(string.byte_size(prefix))
            <> "\r\n"
            <> prefix
            <> "\r\n",
          ),
        )
      process.send(closed, tcp.recv(socket, 0, 3000))
      tcp.close(socket)
    })
  let config =
    provider.new(
      message.Custom("exception-test"),
      "http://127.0.0.1:" <> int.to_string(server.port),
      fn(_request, _tools, _format) { Ok(provider.encoded("/events", "{}")) },
      fn() {
        provider.reducer(
          Nil,
          fn(_, _) { panic as "controlled reducer exception" },
          fn(_) { None },
        )
      },
    )
    |> provider.config
  let assert Ok(call) = llm_wire.prepare(config, hello())
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  let consumer =
    process.spawn_unlinked(fn() {
      let _ = llm_wire.run(client, call)
      Nil
    })
  let monitor = process.monitor(consumer)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(3000)
  let assert Ok(Error(_)) = process.receive(closed, 3000)
  wait_released(client, 200) |> should.be_true
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn prepared_buffered_http_gun_test() {
  let assert Ok(server) = fake_server.start()
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
      let _ =
        fake_server.send_sse_stream(
          socket,
          [#(0, bit_array.from_string(text_events()))],
          True,
        )
    })
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  llm_wire.run(client, prepared(server.port, fn(c) { c }))
  |> should.equal(Ok(llm_wire.Answer("hello", "hello", None)))
  http_gun.stop(client)
  fake_server.stop(server)
}

/// The call's own budget replaces HTTP Gun's request timeout, and the client's
/// idle timeout does not cut a slow first token or a gap between events: the
/// semantic owner's timers alone decide.
pub fn client_timeouts_do_not_cut_the_call_budget_test() {
  let assert Ok(server) = fake_server.start()
  let assert [first, ..rest] =
    string.split(text_events(), "event: response.output_text.delta")
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
      process.sleep(300)
      let _ =
        fake_server.send_sse_stream(
          socket,
          [
            #(0, bit_array.from_string(first)),
            #(
              300,
              bit_array.from_string(
                "event: response.output_text.delta"
                <> string.join(rest, "event: response.output_text.delta"),
              ),
            ),
          ],
          True,
        )
    })
  let assert Ok(client) =
    http_gun.start(
      http_test_helpers.loopback_config()
      |> http_config.with_request_timeout(
        http_config.After(duration.milliseconds(100)),
      )
      |> http_config.with_idle_timeout(
        http_config.After(duration.milliseconds(100)),
      ),
    )
  let configure = fn(config) {
    config
    |> llm_wire.with_call_timeout(ms(5000))
    |> llm_wire.with_first_token_timeout(ms(2000))
    |> llm_wire.with_idle_timeout(ms(2000))
  }
  llm_wire.run(client, prepared(server.port, configure))
  |> should.equal(Ok(llm_wire.Answer("hello", "hello", None)))
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn text_events() -> String {
  "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"m\",\"type\":\"message\"}}\n\n"
  <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"m\",\"delta\":\"hello\"}\n\n"
  <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"m\",\"type\":\"message\"}}\n\n"
  <> "event: response.completed\ndata: {\"response\":{\"id\":\"r\",\"status\":\"completed\"}}\n\n"
}

pub fn closed_shared_client_keeps_http_evidence_test() {
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  http_gun.stop(client)
  // HTTP Gun reports a stopped client as `NotSent`; the evidence passes
  // through as `failure.sent`, which replaced the retry evidence.
  let assert Error(failure) = llm_wire.run(client, prepared(1, fn(c) { c }))
  let assert error.Http(http_failure) = failure.error
  http_error.reason(http_failure) |> should.equal(http_error.ClientClosed)
  failure.sent |> should.equal(llm_wire.NotSent)
  failure.partial_output |> should.be_false
}

fn prepared(
  port: Int,
  configure: fn(llm_wire.Config) -> llm_wire.Config,
) -> llm_wire.Prepared(String) {
  let config =
    openai.new("synthetic-key")
    |> openai.config
    |> llm_wire.with_endpoint("http://127.0.0.1:" <> int.to_string(port))
    |> configure
  let assert Ok(call) = llm_wire.prepare(config, hello())
  call
}

pub fn pre_submission_http_limit_keeps_no_request_sent_test() {
  let assert Ok(client) =
    http_gun.start(
      http_test_helpers.loopback_config()
      |> http_config.with_max_request_body_bytes(1),
    )
  let assert Error(failure) = llm_wire.run(client, prepared(1, fn(c) { c }))
  let assert error.Http(http_failure) = failure.error
  let assert http_error.LimitExceeded(http_error.RequestBodyBytes, 1, _) =
    http_error.reason(http_failure)
  failure.sent |> should.equal(llm_wire.NotSent)
  http_gun.stop(client)
}

pub fn pre_header_close_releases_shared_admission_test() {
  let assert Ok(server) = fake_server.start()
  let accepted = process.new_subject()
  let released = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
      process.send(accepted, Nil)
      let result = tcp.recv(socket, 0, 3000)
      process.send(released, result)
      tcp.close(socket)
    })
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  let assert Ok(stream) =
    llm_wire.stream(client, prepared(server.port, fn(c) { c }))
  let assert Ok(Nil) = process.receive(accepted, 2000)
  llm_wire.close(stream) |> should.equal(llm_wire.Closed)
  llm_wire.close(stream) |> should.equal(llm_wire.AlreadyEnded)
  let assert Ok(Error(_)) = process.receive(released, 2000)
  wait_released(client, 200) |> should.be_true
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn close_during_tls_connection_setup_releases_request_test() {
  // A TCP peer accepts ClientHello but never supplies ServerHello. This keeps
  // the request in connection setup, before request submission or headers.
  let assert Ok(server) = fake_server.start()
  let connecting = process.new_subject()
  let closed = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = tcp.recv(socket, 0, 3000)
      process.send(connecting, Nil)
      process.send(closed, await_tls_socket_close(socket, 8))
      tcp.close(socket)
    })
  let config =
    openai.new("synthetic-key")
    |> openai.config
    |> llm_wire.with_endpoint(
      "https://127.0.0.1:" <> int.to_string(server.port),
    )
  let assert Ok(call) = llm_wire.prepare(config, hello())
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  let assert Ok(stream) = llm_wire.stream(client, call)
  let assert Ok(Nil) = process.receive(connecting, 2000)
  llm_wire.close(stream) |> should.equal(llm_wire.Closed)
  let assert Ok(Ok(Nil)) = process.receive(closed, 2000)
  wait_released(client, 200) |> should.be_true
  http_gun.stop(client)
  fake_server.stop(server)
}

fn await_tls_socket_close(
  socket: tcp.Socket,
  remaining: Int,
) -> Result(Nil, String) {
  case tcp.recv(socket, 0, 1000) {
    Error("closed") -> Ok(Nil)
    Error(reason) -> Error(reason)
    Ok(_) if remaining > 0 -> await_tls_socket_close(socket, remaining - 1)
    Ok(_) -> Error("too many records while awaiting TLS close")
  }
}

fn wait_released(client: http_gun.Client, attempts: Int) -> Bool {
  let assert Ok(stats) = http_gun.stats(client)
  case stats.open_bodies == 0 && stats.queued_requests == 0, attempts {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(5)
      wait_released(client, attempts - 1)
    }
  }
}

pub fn consumer_read_timeout_preserves_http_and_terminal_precedes_eof_test() {
  let assert Ok(server) = fake_server.start()
  let gate = process.new_subject()
  let closed = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let release = process.new_subject()
      process.send(gate, release)
      let assert Ok(socket) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
      let assert Ok(Nil) =
        tcp.send(socket, <<
          "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n":utf8,
        >>)
      let assert Ok(Nil) = process.receive(release, 3000)
      let events = text_events()
      let assert Ok(Nil) =
        tcp.send(
          socket,
          bit_array.from_string(
            int.to_base16(string.byte_size(events))
            <> "\r\n"
            <> events
            <> "\r\n",
          ),
        )
      // Deliberately never send HTTP's final zero chunk.
      process.send(closed, tcp.recv(socket, 0, 3000))
      tcp.close(socket)
    })
  let assert Ok(release) = process.receive(gate, 1000)
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  let configure = fn(config) {
    config
    |> llm_wire.with_call_timeout(ms(5000))
    |> llm_wire.with_first_token_timeout(ms(3000))
  }
  let assert Ok(stream) =
    llm_wire.stream(client, prepared(server.port, configure))
  // `next` now waits for an event; a bounded read is `next_within`, which
  // gives up with `TimedOut` and leaves the stream readable.
  llm_wire.next_within(stream, duration.milliseconds(10))
  |> should.equal(Error(llm_wire.TimedOut))
  process.send(release, Nil)
  llm_wire.collect(stream)
  |> should.equal(Ok(llm_wire.Answer("hello", "hello", None)))
  let assert Ok(Error(_)) = process.receive(closed, 2000)
  wait_released(client, 200) |> should.be_true
  http_gun.stop(client)
  fake_server.stop(server)
}

fn serve_then_ping(
  server: fake_server.FakeServer,
  opening: String,
  pings: Int,
) -> Nil {
  let assert Ok(socket) = fake_server.accept_connection(server, 5000)
  let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
  let _ =
    fake_server.send_sse_stream(
      socket,
      [
        #(0, bit_array.from_string(opening)),
        ..list.repeat(#(20, <<": ping\r\n\r\n":utf8>>), pings)
      ],
      True,
    )
  Nil
}

/// SSE comments are bytes, not events: they reset neither timer. Before any
/// progress the first-token timer fires (the old idle deadline ran from the
/// start); after progress the idle gap fires.
pub fn keepalive_bytes_do_not_extend_semantic_idle_test() {
  let assert Ok(server) = fake_server.start()
  let _ = process.spawn_unlinked(fn() { serve_then_ping(server, "", 100) })
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  let configure = fn(config) {
    config
    |> llm_wire.with_call_timeout(ms(5000))
    |> llm_wire.with_first_token_timeout(ms(150))
  }
  let assert Error(failure) =
    llm_wire.run(client, prepared(server.port, configure))
  failure.error |> should.equal(error.DeadlineExceeded(error.FirstToken))
  failure.sent |> should.equal(llm_wire.MaybeSent)
  failure.partial_output |> should.be_false
  wait_released(client, 200) |> should.be_true
  fake_server.stop(server)

  let assert [opening, ..] =
    string.split(text_events(), "event: response.output_item.done")
  let assert Ok(server) = fake_server.start()
  let _ = process.spawn_unlinked(fn() { serve_then_ping(server, opening, 100) })
  let configure = fn(config) {
    config
    |> llm_wire.with_call_timeout(ms(5000))
    |> llm_wire.with_idle_timeout(ms(150))
  }
  let assert Error(failure) =
    llm_wire.run(client, prepared(server.port, configure))
  failure.error |> should.equal(error.DeadlineExceeded(error.IdleGap))
  failure.partial_output |> should.be_true
  wait_released(client, 200) |> should.be_true
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn partial_status_body_keeps_bytes_when_semantic_idle_wins_test() {
  let assert Ok(server) = fake_server.start()
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
      let assert Ok(Nil) =
        tcp.send(socket, <<
          "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nerr\r\n":utf8,
        >>)
      let _ = tcp.recv(socket, 0, 3000)
      tcp.close(socket)
    })
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  let configure = fn(config) {
    config
    |> llm_wire.with_call_timeout(ms(5000))
    |> llm_wire.with_first_token_timeout(ms(150))
  }
  // The first-token timer covers the response head and a status body; it
  // replaces the old idle deadline here. Response bytes are no longer
  // reported separately: the request reached the provider, so `MaybeSent`.
  let assert Error(failure) =
    llm_wire.run(client, prepared(server.port, configure))
  failure.error |> should.equal(error.DeadlineExceeded(error.FirstToken))
  failure.sent |> should.equal(llm_wire.MaybeSent)
  failure.partial_output |> should.be_false
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn execution_starts_budget_and_delayed_headers_spend_it_test() {
  let assert Ok(server) = fake_server.start()
  let accepted = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
      process.send(accepted, Nil)
      let _ = tcp.recv(socket, 0, 3000)
      tcp.close(socket)
    })
  let call = prepared(server.port, llm_wire.with_call_timeout(_, ms(400)))
  // Waiting longer than the budget after `prepare` spends none of it.
  process.sleep(500)
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  let assert Error(failure) = llm_wire.run(client, call)
  failure.error |> should.equal(error.DeadlineExceeded(error.WholeCall))
  let assert Ok(Nil) = process.receive(accepted, 1000)
  wait_released(client, 200) |> should.be_true
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn disconnect_preserves_raw_and_semantic_evidence_test() {
  let prefix =
    text_events()
    |> string.split("event: response.output_item.done")
    |> list.first
    |> should.be_ok
  list.each([#("event: incom", False), #(prefix, True)], fn(input) {
    let assert Ok(server) = fake_server.start()
    let _ =
      process.spawn_unlinked(fn() {
        let assert Ok(socket) = fake_server.accept_connection(server, 5000)
        let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
        let _ =
          fake_server.send_sse_stream(
            socket,
            [#(0, bit_array.from_string(input.0))],
            True,
          )
      })
    let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
    // Response bytes are no longer reported apart from `sent`; semantic
    // progress is `partial_output`.
    let assert Error(failure) =
      llm_wire.run(client, prepared(server.port, fn(c) { c }))
    failure.partial_output |> should.equal(input.1)
    failure.sent |> should.equal(llm_wire.MaybeSent)
    http_gun.stop(client)
    fake_server.stop(server)
  })
}

pub fn consumer_death_cancels_worker_before_headers_test() {
  let assert Ok(server) = fake_server.start()
  let accepted = process.new_subject()
  let closed = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
      process.send(accepted, Nil)
      process.send(closed, tcp.recv(socket, 0, 3000))
      tcp.close(socket)
    })
  let assert Ok(client) = http_gun.start(http_test_helpers.loopback_config())
  let ready = process.new_subject()
  let call = prepared(server.port, fn(c) { c })
  let consumer =
    process.spawn_unlinked(fn() {
      let assert Ok(stream) = llm_wire.stream(client, call)
      process.send(ready, stream)
      process.sleep(5000)
    })
  let assert Ok(_) = process.receive(ready, 1000)
  let assert Ok(Nil) = process.receive(accepted, 1000)
  process.kill(consumer)
  let assert Ok(Error(_)) = process.receive(closed, 2000)
  wait_released(client, 200) |> should.be_true
  http_gun.stop(client)
  fake_server.stop(server)
}
