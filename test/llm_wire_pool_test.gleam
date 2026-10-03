//// Shared-client LLM scenarios retained from the former pool suite.

import fake_server
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/config as http_config
import http_gun/error as http_error
import http_test_helpers
import llm_wire
import llm_wire/error
import llm_wire/openai
import llm_wire_http_gun_test

fn settings(active: Int, waiting: Int, connections: Int) -> http_config.Config {
  http_test_helpers.loopback_config()
  |> http_config.with_max_open_bodies(active)
  |> http_config.with_max_queued_requests(waiting)
  |> http_config.with_max_connections(connections)
  |> http_config.with_max_connections_per_origin(connections)
}

fn ms(value: Int) -> llm_wire.Bound {
  llm_wire.After(duration.milliseconds(value))
}

fn request(port: Int, timeout: Int) -> llm_wire.Prepared(String) {
  // The old 4 s idle deadline ran from the start: it is now the first-token
  // timer, with the same bound on the gap between events.
  let config =
    openai.new("synthetic-pool-key")
    |> openai.config
    |> llm_wire.with_endpoint("http://127.0.0.1:" <> int.to_string(port))
    |> llm_wire.with_call_timeout(ms(timeout))
    |> llm_wire.with_first_token_timeout(ms(4000))
    |> llm_wire.with_idle_timeout(ms(4000))
  let assert Ok(call) =
    llm_wire.prepare(
      config,
      llm_wire.request("fixture", [llm_wire.user("hello")]),
    )
  call
}

fn hello() -> Result(llm_wire.Outcome(String), llm_wire.Failure) {
  Ok(llm_wire.Answer("hello", "hello", None))
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
  let assert Ok(stats) = http_gun.stats(client)
  case stats.open_bodies == bodies && stats.queued_requests == waiting, tries {
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
  let assert Ok(snapshot) = http_gun.stats(client)
  #(snapshot.connections, snapshot.open_bodies, snapshot.queued_requests)
  |> should.equal(#(0, 0, 0))
  http_gun.stop(client)
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
    llm_wire.run(client, call)
    |> should.equal(hello())
  })
  let assert Ok(Nil) = process.receive(completed, 1000)
  let assert Ok(stats) = http_gun.stats(client)
  stats.connections |> should.equal(1)
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn peer_close_reclaims_connection_for_fresh_call_test() {
  let #(server, accepted) = holding(2)
  let assert Ok(client) = http_gun.start(settings(1, 1, 1))
  list.each([1, 2], fn(_) {
    let assert Ok(stream) = llm_wire.stream(client, request(server.port, 2000))
    let assert Ok(release) = process.receive(accepted, 1000)
    process.send(release, Nil)
    llm_wire.collect(stream) |> should.equal(hello())
  })
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn queue_deadline_releases_only_its_waiter_test() {
  let #(server, accepted) = holding(1)
  let assert Ok(client) = http_gun.start(settings(1, 2, 1))
  let assert Ok(first) = llm_wire.stream(client, request(server.port, 2000))
  let assert Ok(release) = process.receive(accepted, 1000)
  let assert Error(failure) = llm_wire.run(client, request(server.port, 50))
  failure.error |> should.equal(error.DeadlineExceeded(error.WholeCall))
  wait_counts(client, 1, 0, 200) |> should.be_true
  process.send(release, Nil)
  llm_wire.collect(first) |> should.equal(hello())
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn queued_call_runs_after_first_finishes_test() {
  let #(server, accepted) = holding(2)
  let assert Ok(client) = http_gun.start(settings(1, 2, 1))
  let call = request(server.port, 3000)
  let assert Ok(first) = llm_wire.stream(client, call)
  let assert Ok(release) = process.receive(accepted, 1000)
  let assert Ok(second) = llm_wire.stream(client, call)
  wait_counts(client, 1, 1, 200) |> should.be_true
  process.send(release, Nil)
  llm_wire.collect(first) |> should.equal(hello())
  let assert Ok(release) = process.receive(accepted, 1000)
  process.send(release, Nil)
  llm_wire.collect(second) |> should.equal(hello())
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn queued_cancellation_does_not_consume_connection_or_disturb_owner_test() {
  let #(server, accepted) = holding(1)
  let assert Ok(client) = http_gun.start(settings(1, 1, 1))
  let call = request(server.port, 3000)
  let assert Ok(first) = llm_wire.stream(client, call)
  let assert Ok(release) = process.receive(accepted, 1000)
  let assert Ok(second) = llm_wire.stream(client, call)
  wait_counts(client, 1, 1, 200) |> should.be_true
  llm_wire.close(second) |> should.equal(llm_wire.Closed)
  wait_counts(client, 1, 0, 200) |> should.be_true
  process.send(release, Nil)
  llm_wire.collect(first) |> should.equal(hello())
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn admission_overflow_is_not_submitted_test() {
  let #(server, accepted) = holding(1)
  let assert Ok(client) = http_gun.start(settings(1, 1, 1))
  let call = request(server.port, 3000)
  let assert Ok(first) = llm_wire.stream(client, call)
  let assert Ok(release) = process.receive(accepted, 1000)
  let assert Ok(second) = llm_wire.stream(client, call)
  wait_counts(client, 1, 1, 200) |> should.be_true
  let assert Error(failure) = llm_wire.run(client, call)
  let assert error.Http(http_failure) = failure.error
  http_error.reason(http_failure) |> should.equal(http_error.AdmissionFull)
  // `failure.sent` replaced the retry evidence: nothing reached the network.
  failure.sent |> should.equal(llm_wire.NotSent)
  failure.partial_output |> should.be_false
  let _ = llm_wire.close(second)
  let _ = llm_wire.close(first)
  process.send(release, Nil)
  http_gun.stop(client)
  fake_server.stop(server)
}

pub fn shared_client_shutdown_unblocks_active_and_waiting_calls_test() {
  let #(server, accepted) = holding(1)
  let assert Ok(client) = http_gun.start(settings(1, 1, 1))
  let call = request(server.port, 3000)
  let assert Ok(first) = llm_wire.stream(client, call)
  let assert Ok(release) = process.receive(accepted, 1000)
  let assert Ok(second) = llm_wire.stream(client, call)
  wait_counts(client, 1, 1, 200) |> should.be_true
  http_gun.stop(client)
  llm_wire.collect(first) |> should.be_error
  llm_wire.collect(second) |> should.be_error
  process.send(release, Nil)
  fake_server.stop(server)
}
