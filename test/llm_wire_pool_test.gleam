//// Shared-client LLM scenarios retained from the former pool suite.

import fake_server
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleeunit/should
import http_gun
import http_gun/config as http_config
import http_gun/error
import llm_wire/config
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/types
import llm_wire_http_gun_test

fn settings(active: Int, waiting: Int, connections: Int) -> http_config.Config {
  let base = http_config.default()
  http_config.Config(
    ..base,
    deadline_ms: 5000,
    limits: http_config.Limits(
      ..base.limits,
      active: active,
      waiting: waiting,
      connections: connections,
      per_origin: connections,
    ),
  )
}

fn request(port: Int, timeout: Int) -> session.PreparedCall {
  let assert Ok(key) = types.api_key("synthetic-pool-key")
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(port))
  let assert Ok(model) = types.model_id("fixture")
  let provider =
    config.openai(openai.options(key))
    |> config.with_endpoint(endpoint)
    |> config.with_deadlines(types.Deadlines(timeout, 4000, 50))
  let assert Ok(call) =
    session.prepare(
      provider,
      types.new_request(model, [types.UserMessage("hello")]),
    )
  call
}

fn holding(
  count: Int,
) -> #(fake_server.FakeServer, process.Subject(process.Subject(Nil))) {
  let assert Ok(server) = fake_server.start()
  let accepted = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() { serve_holding(server, count, accepted) })
  #(server, accepted)
}

fn serve_holding(
  server: fake_server.FakeServer,
  count: Int,
  accepted: process.Subject(process.Subject(Nil)),
) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      let assert Ok(socket) = fake_server.accept_connection(server, 5000)
      let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
      let release = process.new_subject()
      process.send(accepted, release)
      let _ = process.receive(release, 3000)
      let _ =
        fake_server.send_sse_stream(
          socket,
          [#(0, <<llm_wire_http_gun_test.text_events():utf8>>)],
          True,
        )
      serve_holding(server, count - 1, accepted)
    }
  }
}

fn wait_counts(
  client: http_gun.Client,
  bodies: Int,
  waiting: Int,
  tries: Int,
) -> Bool {
  let assert Ok(stats) = http_gun.snapshot(client)
  case stats.bodies == bodies && stats.waiting == waiting, tries {
    True, _ -> True
    False, 0 -> False
    False, _ -> {
      process.sleep(5)
      wait_counts(client, bodies, waiting, tries - 1)
    }
  }
}

pub fn shared_client_lifecycle_and_invalid_limits_test() {
  http_gun.start(settings(0, 0, 0)) |> should.be_error
  let assert Ok(client) = http_gun.start(settings(1, 1, 1))
  let assert Ok(snapshot) = http_gun.snapshot(client)
  #(snapshot.connections, snapshot.bodies, snapshot.waiting)
  |> should.equal(#(0, 0, 0))
  let assert Ok(Nil) = http_gun.stop(client)
}

pub fn sequential_llm_requests_reuse_one_connection_test() {
  let assert Ok(server) = fake_server.start()
  let completed = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 5000)
      list.each([1, 2], fn(_) {
        let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
        let assert Ok(Nil) =
          fake_server.send_chunked_sse_keepalive(
            socket,
            llm_wire_http_gun_test.text_events(),
          )
      })
      process.send(completed, Nil)
      process.sleep(1000)
    })
  let assert Ok(client) = http_gun.start(settings(2, 2, 1))
  let call = request(server.port, 2000)
  list.each([1, 2], fn(_) {
    session.run(client, call)
    |> should.equal(Ok(session.RunText("hello", None)))
  })
  let assert Ok(Nil) = process.receive(completed, 1000)
  let assert Ok(stats) = http_gun.snapshot(client)
  stats.connections |> should.equal(1)
  let assert Ok(Nil) = http_gun.stop(client)
  fake_server.stop(server)
}

pub fn peer_close_reclaims_connection_for_fresh_call_test() {
  let #(server, accepted) = holding(2)
  let assert Ok(client) = http_gun.start(settings(1, 1, 1))
  list.each([1, 2], fn(_) {
    let assert Ok(stream) = session.stream(client, request(server.port, 2000))
    let assert Ok(release) = process.receive(accepted, 1000)
    process.send(release, Nil)
    session.collect(stream) |> should.equal(Ok(session.RunText("hello", None)))
  })
  let assert Ok(Nil) = http_gun.stop(client)
  fake_server.stop(server)
}

pub fn queue_deadline_releases_only_its_waiter_test() {
  let #(server, accepted) = holding(1)
  let assert Ok(client) = http_gun.start(settings(1, 2, 1))
  let assert Ok(first) = session.stream(client, request(server.port, 2000))
  let assert Ok(release) = process.receive(accepted, 1000)
  let assert Error(session.RunFailure(
    types.DeadlineExceeded(types.OverallDeadline),
    _,
  )) = session.run(client, request(server.port, 50))
  wait_counts(client, 1, 0, 200) |> should.be_true
  process.send(release, Nil)
  session.collect(first) |> should.equal(Ok(session.RunText("hello", None)))
  let assert Ok(Nil) = http_gun.stop(client)
  fake_server.stop(server)
}

pub fn queued_call_runs_after_first_finishes_test() {
  let #(server, accepted) = holding(2)
  let assert Ok(client) = http_gun.start(settings(1, 2, 1))
  let call = request(server.port, 3000)
  let assert Ok(first) = session.stream(client, call)
  let assert Ok(release) = process.receive(accepted, 1000)
  let assert Ok(second) = session.stream(client, call)
  wait_counts(client, 1, 1, 200) |> should.be_true
  process.send(release, Nil)
  session.collect(first) |> should.equal(Ok(session.RunText("hello", None)))
  let assert Ok(release) = process.receive(accepted, 1000)
  process.send(release, Nil)
  session.collect(second) |> should.equal(Ok(session.RunText("hello", None)))
  let assert Ok(Nil) = http_gun.stop(client)
  fake_server.stop(server)
}

pub fn queued_cancellation_does_not_consume_connection_or_disturb_owner_test() {
  let #(server, accepted) = holding(1)
  let assert Ok(client) = http_gun.start(settings(1, 1, 1))
  let call = request(server.port, 3000)
  let assert Ok(first) = session.stream(client, call)
  let assert Ok(release) = process.receive(accepted, 1000)
  let assert Ok(second) = session.stream(client, call)
  wait_counts(client, 1, 1, 200) |> should.be_true
  session.close(second) |> should.equal(Ok(types.ConsumerClosed))
  wait_counts(client, 1, 0, 200) |> should.be_true
  process.send(release, Nil)
  session.collect(first) |> should.equal(Ok(session.RunText("hello", None)))
  let assert Ok(Nil) = http_gun.stop(client)
  fake_server.stop(server)
}

pub fn admission_overflow_is_not_submitted_test() {
  let #(server, accepted) = holding(1)
  let assert Ok(client) = http_gun.start(settings(1, 1, 1))
  let call = request(server.port, 3000)
  let assert Ok(first) = session.stream(client, call)
  let assert Ok(release) = process.receive(accepted, 1000)
  let assert Ok(second) = session.stream(client, call)
  wait_counts(client, 1, 1, 200) |> should.be_true
  let assert Error(session.RunFailure(
    types.HttpFailure(error.AdmissionFull),
    evidence,
  )) = session.run(client, call)
  evidence |> should.equal(types.initial_retry_evidence())
  let _ = session.close(second)
  let _ = session.close(first)
  process.send(release, Nil)
  let assert Ok(Nil) = http_gun.stop(client)
  fake_server.stop(server)
}

pub fn shared_client_shutdown_unblocks_active_and_waiting_calls_test() {
  let #(server, accepted) = holding(1)
  let assert Ok(client) = http_gun.start(settings(1, 1, 1))
  let call = request(server.port, 3000)
  let assert Ok(first) = session.stream(client, call)
  let assert Ok(release) = process.receive(accepted, 1000)
  let assert Ok(second) = session.stream(client, call)
  wait_counts(client, 1, 1, 200) |> should.be_true
  let assert Ok(Nil) = http_gun.stop(client)
  session.collect(first) |> should.be_error
  session.collect(second) |> should.be_error
  process.send(release, Nil)
  fake_server.stop(server)
}
