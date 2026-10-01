import external_provider
import fake_server
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import http_gun
import http_gun/config as http_config
import http_gun/error as http_error
import llm_wire/config
import llm_wire/provider
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/types
import llm_wire_test_tcp as tcp

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
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(server.port))
  let base = external_provider.adapter(endpoint)
  let adapter =
    provider.adapter(
      provider.Spec(
        identity: types.Custom("exception-test"),
        endpoint: endpoint,
        headers: [],
        encode: fn(request, tools, format) {
          provider.encode(base, request, tools, format)
        },
        project_tool_schema: provider.blueprint_schema,
        project_output_schema: provider.blueprint_schema,
        new_reducer: fn(_, _) {
          Ok(
            provider.reducer(
              Nil,
              fn(_, _) { panic as "controlled reducer exception" },
              fn(_) { None },
              fn(_, fallback) { types.RetryEvidence(fallback, False, False) },
            ),
          )
        },
      ),
    )
  let assert Ok(model) = types.model_id("fixture")
  let assert Ok(call) =
    session.prepare(
      config.from_provider(adapter),
      types.new_request(model, [types.UserMessage("hello")]),
    )
  let assert Ok(client) = http_gun.start(http_config.default())
  let consumer =
    process.spawn_unlinked(fn() {
      let _ = session.run(client, call)
      Nil
    })
  let monitor = process.monitor(consumer)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(3000)
  let assert Ok(Error(_)) = process.receive(closed, 3000)
  wait_released(client, 200) |> should.be_true
  let assert Ok(Nil) = http_gun.stop(client)
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
  let assert Ok(key) = types.api_key("synthetic-key")
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(server.port))
  let assert Ok(model) = types.model_id("fixture")
  let settings =
    config.openai(openai.options(key)) |> config.with_endpoint(endpoint)
  let assert Ok(prepared) =
    session.prepare(
      settings,
      types.new_request(model, [types.UserMessage("hi")]),
    )
  let assert Ok(client) =
    http_gun.start(
      http_config.Config(..http_config.default(), deadline_ms: 60_000),
    )
  session.run(client, prepared)
  |> should.equal(Ok(session.RunText("hello", None)))
  let assert Ok(Nil) = http_gun.stop(client)
  fake_server.stop(server)
}

pub fn text_events() -> String {
  "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"m\",\"type\":\"message\"}}\n\n"
  <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"m\",\"delta\":\"hello\"}\n\n"
  <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"m\",\"type\":\"message\"}}\n\n"
  <> "event: response.completed\ndata: {\"response\":{\"id\":\"r\",\"status\":\"completed\"}}\n\n"
}

pub fn closed_shared_client_keeps_conservative_http_evidence_test() {
  let assert Ok(client) = http_gun.start(http_config.default())
  let assert Ok(Nil) = http_gun.stop(client)
  let assert Error(session.RunFailure(
    types.HttpFailure(http_error.ClientClosed),
    retry,
  )) = session.run(client, prepared(1, types.default_deadlines()))
  retry
  |> should.equal(types.RetryEvidence(
    types.RequestMayHaveReachedProvider,
    False,
    False,
  ))
}

fn prepared(port: Int, deadlines: types.Deadlines) -> session.PreparedCall {
  let assert Ok(key) = types.api_key("synthetic-key")
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(port))
  let assert Ok(model) = types.model_id("fixture")
  let settings =
    config.openai(openai.options(key))
    |> config.with_endpoint(endpoint)
    |> config.with_deadlines(deadlines)
  let assert Ok(call) =
    session.prepare(
      settings,
      types.new_request(model, [types.UserMessage("hi")]),
    )
  call
}

pub fn pre_submission_http_limit_keeps_no_request_sent_test() {
  let defaults = http_config.default()
  let assert Ok(client) =
    http_gun.start(
      http_config.Config(
        ..defaults,
        limits: http_config.Limits(..defaults.limits, request_bytes: 1),
      ),
    )
  let assert Error(session.RunFailure(
    types.HttpFailure(http_error.LimitExceeded(
      http_error.RequestBodyBytes,
      1,
      _,
    )),
    retry,
  )) = session.run(client, prepared(1, types.default_deadlines()))
  retry |> should.equal(types.initial_retry_evidence())
  let assert Ok(Nil) = http_gun.stop(client)
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
  let assert Ok(client) = http_gun.start(http_config.default())
  let assert Ok(stream) =
    session.stream(client, prepared(server.port, types.default_deadlines()))
  let assert Ok(Nil) = process.receive(accepted, 2000)
  session.close(stream) |> should.equal(Ok(types.ConsumerClosed))
  session.close(stream) |> should.equal(Ok(types.AlreadyTerminal))
  let assert Ok(Error(_)) = process.receive(released, 2000)
  wait_released(client, 200) |> should.be_true
  let assert Ok(Nil) = http_gun.stop(client)
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
  let assert Ok(endpoint) =
    types.endpoint("https://127.0.0.1:" <> int.to_string(server.port))
  let assert Ok(key) = types.api_key("synthetic-key")
  let assert Ok(model) = types.model_id("fixture")
  let assert Ok(call) =
    session.prepare(
      config.openai(openai.options(key)) |> config.with_endpoint(endpoint),
      types.new_request(model, [types.UserMessage("hello")]),
    )
  let assert Ok(client) = http_gun.start(http_config.default())
  let assert Ok(stream) = session.stream(client, call)
  let assert Ok(Nil) = process.receive(connecting, 2000)
  session.close(stream) |> should.equal(Ok(types.ConsumerClosed))
  let assert Ok(Ok(Nil)) = process.receive(closed, 2000)
  wait_released(client, 200) |> should.be_true
  let assert Ok(Nil) = http_gun.stop(client)
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
  let assert Ok(stats) = http_gun.snapshot(client)
  case stats.bodies == 0 && stats.waiting == 0, attempts {
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
  let assert Ok(client) = http_gun.start(http_config.default())
  let call = prepared(server.port, types.Deadlines(3000, 1000, 10))
  let assert Ok(stream) = session.stream(client, call)
  session.next(stream)
  |> should.equal(Error(session.StreamReadError(types.ReadTimeout)))
  process.send(release, Nil)
  session.collect(stream) |> should.equal(Ok(session.RunText("hello", None)))
  let assert Ok(Error(_)) = process.receive(closed, 2000)
  wait_released(client, 200) |> should.be_true
  let assert Ok(Nil) = http_gun.stop(client)
  fake_server.stop(server)
}

pub fn keepalive_bytes_do_not_extend_semantic_idle_test() {
  let assert Ok(server) = fake_server.start()
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
      let _ =
        fake_server.send_sse_stream(
          socket,
          list.repeat(#(10, <<": ping\r\n\r\n":utf8>>), 50),
          True,
        )
    })
  let assert Ok(client) = http_gun.start(http_config.default())
  let assert Error(session.RunFailure(
    types.DeadlineExceeded(types.IdleDeadline),
    evidence,
  )) = session.run(client, prepared(server.port, types.Deadlines(2000, 80, 10)))
  evidence.response_bytes_observed |> should.be_true
  evidence.semantic_progress_observed |> should.be_false
  wait_released(client, 200) |> should.be_true
  let assert Ok(Nil) = http_gun.stop(client)
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
      let _ = tcp.recv(socket, 0, 2000)
      tcp.close(socket)
    })
  let assert Ok(client) = http_gun.start(http_config.default())
  let assert Error(session.RunFailure(
    types.DeadlineExceeded(types.IdleDeadline),
    evidence,
  )) =
    session.run(client, prepared(server.port, types.Deadlines(3000, 100, 10)))
  evidence.response_bytes_observed |> should.be_true
  evidence.semantic_progress_observed |> should.be_false
  let assert Ok(Nil) = http_gun.stop(client)
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
      let _ = tcp.recv(socket, 0, 1000)
      tcp.close(socket)
    })
  let call = prepared(server.port, types.Deadlines(80, 2000, 10))
  process.sleep(100)
  let assert Ok(client) = http_gun.start(http_config.default())
  let assert Error(session.RunFailure(
    types.DeadlineExceeded(types.OverallDeadline),
    _,
  )) = session.run(client, call)
  let assert Ok(Nil) = process.receive(accepted, 0)
  wait_released(client, 200) |> should.be_true
  let assert Ok(Nil) = http_gun.stop(client)
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
    let assert Ok(client) = http_gun.start(http_config.default())
    let assert Error(session.RunFailure(_, evidence)) =
      session.run(client, prepared(server.port, types.default_deadlines()))
    evidence.response_bytes_observed |> should.be_true
    evidence.semantic_progress_observed |> should.equal(input.1)
    evidence.classification |> should.equal(types.RequestMayHaveReachedProvider)
    let assert Ok(Nil) = http_gun.stop(client)
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
  let assert Ok(client) = http_gun.start(http_config.default())
  let ready = process.new_subject()
  let call = prepared(server.port, types.default_deadlines())
  let consumer =
    process.spawn_unlinked(fn() {
      let assert Ok(stream) = session.stream(client, call)
      process.send(ready, stream)
      process.sleep(5000)
    })
  let assert Ok(_) = process.receive(ready, 1000)
  let assert Ok(Nil) = process.receive(accepted, 1000)
  process.kill(consumer)
  let assert Ok(Error(_)) = process.receive(closed, 2000)
  wait_released(client, 200) |> should.be_true
  let assert Ok(Nil) = http_gun.stop(client)
  fake_server.stop(server)
}
