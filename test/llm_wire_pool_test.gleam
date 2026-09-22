import fake_server
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/option.{None}
import gleam/string
import gleeunit/should
import llm_wire
import llm_wire/owner
import llm_wire/pool
import llm_wire/tcp
import llm_wire/types

fn test_request(model_name: String) -> types.Request {
  let assert Ok(model) = llm_wire.model_id(model_name)
  llm_wire.new_request(model, [llm_wire.UserMessage("hello")])
}

fn openai_prepared(port: Int, model_name: String) -> llm_wire.PreparedCall {
  let assert Ok(key) = llm_wire.api_key("sk-test-key")
  let assert Ok(ep) =
    llm_wire.endpoint("http://127.0.0.1:" <> string.inspect(port) <> "/v1")
  let config = llm_wire.openai_config(key, ep, None, None)
  let request = test_request(model_name)
  let assert Ok(prep) =
    llm_wire.prepare(config, request, llm_wire.default_limits())
  prep
}

pub fn pool_lifecycle_starts_reports_info_and_stops_cleanly_test() {
  let config =
    pool.PoolConfig(
      max_connections_per_target: 3,
      max_total_connections: 10,
      idle_timeout_ms: 10_000,
    )
  let assert Ok(p) = llm_wire.start_pool(config)
  let info0 = llm_wire.pool_info(p)
  let assert True = info0.total_connections == 0
  let assert True = info0.idle_connections == 0
  let assert True = info0.leased_connections == 0
  let assert True = info0.waiting_requests == 0

  let assert Ok(Nil) = llm_wire.stop_pool(p)
}

pub fn pool_reuses_connection_for_sequential_requests_test() {
  let assert Ok(server) = fake_server.start()
  let config =
    pool.PoolConfig(
      max_connections_per_target: 2,
      max_total_connections: 4,
      idle_timeout_ms: 10_000,
    )
  let assert Ok(p) = llm_wire.start_pool(config)

  let sse_body =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item-1\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"item-1\",\"delta\":\"hello\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item-1\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"resp-1\",\"status\":\"completed\"}}\n\n"

  // Server background task: accepts ONE connection, and handles TWO sequential requests on it!
  let _server_task =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 3000)
      // Request 1
      let assert Ok(_req1) = fake_server.read_request_headers(socket, 3000)
      let assert Ok(Nil) =
        fake_server.send_chunked_sse_keepalive(socket, sse_body)
      // Request 2 on the SAME socket!
      let assert Ok(_req2) = fake_server.read_request_headers(socket, 3000)
      let assert Ok(Nil) =
        fake_server.send_chunked_sse_keepalive(socket, sse_body)
      process.sleep(1000)
      Nil
    })

  let prep = openai_prepared(server.port, "gpt-4o")

  // First run through pool
  let assert Ok(llm_wire.RunText(text1, _)) =
    llm_wire.run_with_pool(
      p,
      prep,
      llm_wire.default_limits(),
      llm_wire.default_deadlines(),
    )
  let assert True = text1 == "hello"

  let info_after_1 = llm_wire.pool_info(p)
  let assert True = info_after_1.total_connections == 1
  let assert True = info_after_1.idle_connections == 1
  let assert True = info_after_1.leased_connections == 0

  // Second run through pool: must reuse the connection and succeed on the same socket!
  let assert Ok(llm_wire.RunText(text2, _)) =
    llm_wire.run_with_pool(
      p,
      prep,
      llm_wire.default_limits(),
      llm_wire.default_deadlines(),
    )
  let assert True = text2 == "hello"

  let info_after_2 = llm_wire.pool_info(p)
  let assert True = info_after_2.total_connections == 1
  let assert True = info_after_2.idle_connections == 1

  let assert Ok(Nil) = llm_wire.stop_pool(p)
  fake_server.stop(server)
}

pub fn pool_remote_connection_death_reclaims_entry_test() {
  let assert Ok(server) = fake_server.start()
  let config =
    pool.PoolConfig(
      max_connections_per_target: 1,
      max_total_connections: 1,
      idle_timeout_ms: 10_000,
    )
  let assert Ok(p) = llm_wire.start_pool(config)
  let response =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"remote\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"remote\",\"delta\":\"closed\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"remote\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"remote\",\"status\":\"completed\"}}\n\n"

  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 3000)
    let assert Ok(_) = fake_server.read_request_headers(socket, 3000)
    let assert Ok(Nil) =
      fake_server.send_sse_stream(
        socket,
        [#(0, bit_array.from_string(response))],
        True,
      )
    let assert Ok(socket2) = fake_server.accept_connection(server, 3000)
    let assert Ok(_) = fake_server.read_request_headers(socket2, 3000)
    let assert Ok(Nil) =
      fake_server.send_sse_stream(
        socket2,
        [#(0, bit_array.from_string(response))],
        True,
      )
    Nil
  })

  let prep = openai_prepared(server.port, "gpt-4o")
  let assert Ok(llm_wire.RunText(text, _)) =
    llm_wire.run_with_pool(
      p,
      prep,
      llm_wire.default_limits(),
      llm_wire.default_deadlines(),
    )
  let assert True = text == "closed"

  // The peer closes the socket after the response. The Gun DOWN path must
  // remove the pooled entry and stop the parked connection owner.
  let assert True = wait_for_pool_empty(p, 100)
  let assert Ok(llm_wire.RunText(second_text, _)) =
    llm_wire.run_with_pool(
      p,
      prep,
      llm_wire.default_limits(),
      llm_wire.default_deadlines(),
    )
  let assert True = second_text == "closed"
  let assert Ok(Nil) = llm_wire.stop_pool(p)
  fake_server.stop(server)
}

pub fn pool_stream_isolation_cancelling_stream_a_does_not_affect_stream_b_test() {
  let assert Ok(server) = fake_server.start()
  let config =
    pool.PoolConfig(
      max_connections_per_target: 4,
      max_total_connections: 8,
      idle_timeout_ms: 10_000,
    )
  let assert Ok(p) = llm_wire.start_pool(config)

  let sse_chunk_a =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item-a\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"item-a\",\"delta\":\"partA\"}\n\n"

  let sse_body_b =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item-b\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"item-b\",\"delta\":\"fullB\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item-b\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"resp-b\",\"status\":\"completed\"}}\n\n"

  // Fake server handles two separate connections for the concurrent streams
  process.spawn_unlinked(fn() {
    let assert Ok(sock_a) = fake_server.accept_connection(server, 3000)
    let assert Ok(_req_a) = fake_server.read_request_headers(sock_a, 3000)
    // Send partial chunk to A, don't close yet
    let _ =
      fake_server.send_sse_stream(sock_a, [#(0, <<sse_chunk_a:utf8>>)], False)
    process.sleep(2000)
    Nil
  })

  process.spawn_unlinked(fn() {
    let assert Ok(sock_b) = fake_server.accept_connection(server, 3000)
    let assert Ok(_req_b) = fake_server.read_request_headers(sock_b, 3000)
    // Send full stream to B with small delay
    let _ =
      fake_server.send_sse_stream(sock_b, [#(10, <<sse_body_b:utf8>>)], True)
    Nil
  })

  let prep_a = openai_prepared(server.port, "gpt-4o")
  let prep_b = openai_prepared(server.port, "gpt-4o")

  let assert Ok(stream_a) =
    llm_wire.stream_with_pool(
      p,
      prep_a,
      llm_wire.default_limits(),
      llm_wire.default_deadlines(),
    )

  let assert Ok(stream_b) =
    llm_wire.stream_with_pool(
      p,
      prep_b,
      llm_wire.default_limits(),
      llm_wire.default_deadlines(),
    )

  // Verify stream A receives initial progress
  let assert Ok(types.NextProgress(_)) = owner.next(stream_a, 2000)

  // Explicitly close / cancel stream A!
  let assert Ok(types.ConsumerClosed) = owner.close(stream_a)

  // Verify stream B continues unaffected and completes with full text!
  let assert Ok(types.NextProgress(_)) = owner.next(stream_b, 2000)
  let assert Ok(types.StreamTerminal(types.StreamFinished(
    types.CompletedText("fullB"),
    _,
  ))) = owner.next(stream_b, 2000)

  let assert Ok(Nil) = llm_wire.stop_pool(p)
  fake_server.stop(server)
}

pub fn pool_bounds_resources_and_enforces_waiter_timeout_test() {
  let assert Ok(server) = fake_server.start()
  // Limit to exactly 1 connection per target!
  let config =
    pool.PoolConfig(
      max_connections_per_target: 1,
      max_total_connections: 1,
      idle_timeout_ms: 10_000,
    )
  let assert Ok(p) = llm_wire.start_pool(config)

  let sse_slow =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"slow\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"slow\",\"delta\":\"slow\"}\n\n"

  process.spawn_unlinked(fn() {
    let assert Ok(sock) = fake_server.accept_connection(server, 3000)
    let assert Ok(_) = fake_server.read_request_headers(sock, 3000)
    let _ = fake_server.send_sse_stream(sock, [#(0, <<sse_slow:utf8>>)], False)
    Nil
  })

  let prep = openai_prepared(server.port, "gpt-4o")

  // Stream 1 takes the only available connection
  let assert Ok(stream1) =
    llm_wire.stream_with_pool(
      p,
      prep,
      llm_wire.default_limits(),
      llm_wire.default_deadlines(),
    )

  let info_leased = llm_wire.pool_info(p)
  let assert True = info_leased.leased_connections == 1

  // Stream 2 attempts checkout while Stream 1 holds the connection, with a very tight deadline (60ms)
  let tight_deadlines =
    types.Deadlines(
      overall_timeout_ms: 60,
      read_timeout_ms: 60,
      idle_timeout_ms: 60,
    )
  let result2 =
    llm_wire.stream_with_pool(
      p,
      prep,
      llm_wire.default_limits(),
      tight_deadlines,
    )

  // Must fail due to pool timeout / limit!
  let assert Error(_) = result2

  // Clean up stream 1
  let _ = owner.close(stream1)
  let assert Ok(Nil) = llm_wire.stop_pool(p)
  fake_server.stop(server)
}

pub fn pool_reclaims_connection_upon_client_owner_death_test() {
  let assert Ok(server) = fake_server.start()
  let config =
    pool.PoolConfig(
      max_connections_per_target: 1,
      max_total_connections: 1,
      idle_timeout_ms: 10_000,
    )
  let assert Ok(p) = llm_wire.start_pool(config)

  let sse_data =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"it\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"it\",\"delta\":\"hi\"}\n\n"

  let server_worker =
    process.spawn_unlinked(fn() {
      let assert Ok(sock1) = fake_server.accept_connection(server, 3000)
      let assert Ok(_) = fake_server.read_request_headers(sock1, 3000)
      let _ =
        fake_server.send_sse_stream(sock1, [#(0, <<sse_data:utf8>>)], False)
      // Keep the close-delimited response open while the client owns its stream.
      process.sleep(5000)
      Nil
    })

  let prep = openai_prepared(server.port, "gpt-4o")
  let owner_subject = process.new_subject()

  // Spawn a client that opens a stream and then dies abruptly
  let client_worker =
    process.spawn_unlinked(fn() {
      let assert Ok(stream) =
        llm_wire.stream_with_pool(
          p,
          prep,
          llm_wire.default_limits(),
          llm_wire.default_deadlines(),
        )
      let assert Ok(stream_owner) = owner.owner_pid(stream)
      process.send(owner_subject, stream_owner)
      // Stay alive until killed
      process.sleep(5000)
    })

  let assert Ok(stream_owner) = process.receive(owner_subject, 3000)
  process.sleep(100)
  let info_leased = llm_wire.pool_info(p)
  let lease_was_held = info_leased.leased_connections == 1

  // Kill the client abruptly
  process.kill(client_worker)

  // Owner death must close its bridge and return the lease to the pool.
  let reclaimed = wait_for_pool_reclamation(p, stream_owner, 100)

  let assert Ok(Nil) = llm_wire.stop_pool(p)
  // This is a test-owned peer process. Stop it after the connection assertions.
  process.kill(server_worker)
  fake_server.stop(server)

  let assert True = lease_was_held
  let assert True = reclaimed
}

pub fn pool_waiter_queue_serves_next_request_when_connection_checked_in_test() {
  let assert Ok(server) = fake_server.start()
  // Max 1 connection
  let config =
    pool.PoolConfig(
      max_connections_per_target: 1,
      max_total_connections: 1,
      idle_timeout_ms: 10_000,
    )
  let assert Ok(p) = llm_wire.start_pool(config)

  let sse_body =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"item\",\"delta\":\"ok\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"resp\",\"status\":\"completed\"}}\n\n"

  // Fake server handles two sequential requests on the connection
  process.spawn_unlinked(fn() {
    let assert Ok(sock) = fake_server.accept_connection(server, 3000)
    let assert Ok(_) = fake_server.read_request_headers(sock, 3000)
    let _ = fake_server.send_chunked_sse_keepalive(sock, sse_body)
    let assert Ok(_) = fake_server.read_request_headers(sock, 3000)
    let _ = fake_server.send_chunked_sse_keepalive(sock, sse_body)
    Nil
  })

  let prep = openai_prepared(server.port, "gpt-4o")

  let waiter_subject = process.new_subject()

  // Spawn second request in background waiting with a generous deadline (3000ms)
  process.spawn_unlinked(fn() {
    let res =
      llm_wire.run_with_pool(
        p,
        prep,
        llm_wire.default_limits(),
        types.Deadlines(
          overall_timeout_ms: 3000,
          read_timeout_ms: 3000,
          idle_timeout_ms: 3000,
        ),
      )
    process.send(waiter_subject, res)
  })

  // Give background worker time to attempt checkout and become a waiter in the pool queue
  process.sleep(50)
  let _info_waiting = llm_wire.pool_info(p)
  // Run request 1 on main process
  let assert Ok(llm_wire.RunText(t1, _)) =
    llm_wire.run_with_pool(
      p,
      prep,
      llm_wire.default_limits(),
      llm_wire.default_deadlines(),
    )
  let assert True = t1 == "ok"

  // Now request 2 should have been served by the waiter queue!
  let assert Ok(result2) = process.receive(waiter_subject, 2000)
  let assert Ok(llm_wire.RunText(t2, _)) = result2
  let assert True = t2 == "ok"

  let assert Ok(Nil) = llm_wire.stop_pool(p)
  fake_server.stop(server)
}

pub fn pool_waiter_is_restarted_after_client_cleanup_callback_test() {
  let assert Ok(server) = fake_server.start()
  let config =
    pool.PoolConfig(
      max_connections_per_target: 1,
      max_total_connections: 1,
      idle_timeout_ms: 10_000,
    )
  let assert Ok(p) = llm_wire.start_pool(config)

  let first_response =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"first\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"first\",\"delta\":\"held\"}\n\n"
  let second_response =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"second\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"second\",\"delta\":\"recovered\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"second\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"second\",\"status\":\"completed\"}}\n\n"

  let server_worker =
    process.spawn_unlinked(fn() {
      let assert Ok(sock1) = fake_server.accept_connection(server, 3000)
      let assert Ok(_) = fake_server.read_request_headers(sock1, 3000)
      let _ =
        fake_server.send_sse_stream(
          sock1,
          [#(0, <<first_response:utf8>>)],
          False,
        )
      let assert Ok(sock2) = fake_server.accept_connection(server, 3000)
      let assert Ok(_) = fake_server.read_request_headers(sock2, 3000)
      let _ =
        fake_server.send_sse_stream(
          sock2,
          [#(0, <<second_response:utf8>>)],
          True,
        )
      Nil
    })

  let prep = openai_prepared(server.port, "gpt-4o")
  let owner_subject = process.new_subject()
  let first_client =
    process.spawn_unlinked(fn() {
      let assert Ok(stream) =
        llm_wire.stream_with_pool(
          p,
          prep,
          llm_wire.default_limits(),
          llm_wire.default_deadlines(),
        )
      let assert Ok(stream_owner) = owner.owner_pid(stream)
      process.send(owner_subject, stream_owner)
      process.sleep(5000)
    })
  let assert Ok(stream_owner) = process.receive(owner_subject, 3000)
  let assert True = wait_for_pool_leases(p, 1, 300)

  let waiter_subject = process.new_subject()
  process.spawn_unlinked(fn() {
    let result =
      llm_wire.run_with_pool(
        p,
        prep,
        llm_wire.default_limits(),
        types.Deadlines(
          overall_timeout_ms: 3000,
          read_timeout_ms: 3000,
          idle_timeout_ms: 3000,
        ),
      )
    process.send(waiter_subject, result)
  })
  let assert True = wait_for_pool_waiters(p, 1, 300)

  // Killing the checked-out owner drives the pool's DOWN cleanup callback.
  // The callback must start a replacement connector with a bare pool state.
  process.kill(stream_owner)
  process.kill(first_client)

  let assert Ok(Ok(llm_wire.RunText(text, _))) =
    process.receive(waiter_subject, 3000)
  let assert True = text == "recovered"
  let info = llm_wire.pool_info(p)
  let assert True = info.waiting_requests == 0
  let assert Ok(Nil) = llm_wire.stop_pool(p)
  process.kill(server_worker)
  fake_server.stop(server)
}

fn wait_for_pool_reclamation(
  p: pool.Pool,
  stream_owner: process.Pid,
  attempts: Int,
) -> Bool {
  let info = llm_wire.pool_info(p)
  case info.total_connections == 0 && process.is_alive(stream_owner) == False {
    True -> True
    False ->
      case attempts > 0 {
        True -> {
          process.sleep(10)
          wait_for_pool_reclamation(p, stream_owner, attempts - 1)
        }
        False -> False
      }
  }
}

fn wait_for_pool_empty(p: pool.Pool, attempts: Int) -> Bool {
  let info = llm_wire.pool_info(p)
  case info.total_connections == 0 {
    True -> True
    False ->
      case attempts > 0 {
        True -> {
          process.sleep(10)
          wait_for_pool_empty(p, attempts - 1)
        }
        False -> False
      }
  }
}

fn wait_for_pool_leases(p: pool.Pool, expected: Int, attempts: Int) -> Bool {
  let info = llm_wire.pool_info(p)
  case info.leased_connections == expected {
    True -> True
    False ->
      case attempts > 0 {
        True -> {
          process.sleep(10)
          wait_for_pool_leases(p, expected, attempts - 1)
        }
        False -> False
      }
  }
}

pub fn pool_caps_waiter_queue_and_rejects_invalid_limits_test() {
  let invalid = pool.start(pool.PoolConfig(0, 0, 10_000))
  case invalid {
    Error(types.ConfigurationError(_)) -> Nil
    _ -> should.fail()
  }

  let assert Ok(server) = fake_server.start()
  let config = pool.PoolConfig(1, 1, 10_000)
  let assert Ok(p) = llm_wire.start_pool(config)
  let server_release_ready = process.new_subject()
  let second_result = process.new_subject()
  let first_events =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"first\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"first\",\"delta\":\"first\"}\n\n"
  let first_terminal =
    "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"first\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}\n\n"
  let second_events =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"second\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"second\",\"delta\":\"second\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"second\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"r2\",\"status\":\"completed\"}}\n\n"

  let server_worker =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 3000)
      let assert Ok(_) = fake_server.read_request_headers(socket, 3000)
      let first_header =
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
      let first_chunk =
        int.to_base16(string.byte_size(first_events))
        <> "\r\n"
        <> first_events
        <> "\r\n"
      let _ =
        tcp.send(socket, bit_array.from_string(first_header <> first_chunk))
      let release_server = process.new_subject()
      process.send(server_release_ready, release_server)
      let assert Ok(_) = process.receive(release_server, 4000)
      let terminal_chunk =
        int.to_base16(string.byte_size(first_terminal))
        <> "\r\n"
        <> first_terminal
        <> "\r\n0\r\n\r\n"
      let _ = tcp.send(socket, bit_array.from_string(terminal_chunk))
      let assert Ok(_) = fake_server.read_request_headers(socket, 3000)
      let second_header =
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
      let second_chunk =
        int.to_base16(string.byte_size(second_events))
        <> "\r\n"
        <> second_events
        <> "\r\n0\r\n\r\n"
      let _ =
        tcp.send(socket, bit_array.from_string(second_header <> second_chunk))
      Nil
    })

  let prep = openai_prepared(server.port, "gpt-4o")
  let assert Ok(first_stream) =
    llm_wire.stream_with_pool(
      p,
      prep,
      llm_wire.default_limits(),
      llm_wire.default_deadlines(),
    )
  let assert Ok(release_server) = process.receive(server_release_ready, 2000)
  process.spawn_unlinked(fn() {
    process.send(
      second_result,
      llm_wire.run_with_pool(
        p,
        prep,
        llm_wire.default_limits(),
        llm_wire.default_deadlines(),
      ),
    )
  })
  let assert True = wait_for_pool_waiters(p, 1, 100)
  let over_capacity =
    llm_wire.stream_with_pool(
      p,
      prep,
      llm_wire.default_limits(),
      types.Deadlines(1000, 1000, 1000),
    )
  case over_capacity {
    Error(types.TransportError("pool_limit_reached")) -> Nil
    _ -> should.fail()
  }
  let assert True = llm_wire.pool_info(p).waiting_requests == 1

  process.send(release_server, Nil)
  let assert Ok(types.NextProgress(types.TextDelta(_, "first"))) =
    owner.next(first_stream, 2000)
  let assert Ok(types.StreamTerminal(types.StreamFinished(
    types.CompletedText("first"),
    _,
  ))) = owner.next(first_stream, 2000)
  let assert Ok(Ok(llm_wire.RunText("second", _))) =
    process.receive(second_result, 3000)
  let assert True = wait_for_pool_waiters(p, 0, 100)

  let assert Ok(Nil) = llm_wire.stop_pool(p)
  process.kill(server_worker)
  fake_server.stop(server)
}

fn wait_for_pool_waiters(p: pool.Pool, expected: Int, attempts: Int) -> Bool {
  case llm_wire.pool_info(p).waiting_requests == expected {
    True -> True
    False ->
      case attempts > 0 {
        True -> {
          process.sleep(10)
          wait_for_pool_waiters(p, expected, attempts - 1)
        }
        False -> False
      }
  }
}

pub fn pool_shutdown_unblocks_waiters_and_closes_active_leases_test() {
  let assert Ok(server) = fake_server.start()
  let assert Ok(p) = llm_wire.start_pool(pool.PoolConfig(1, 1, 10_000))
  let server_ready = process.new_subject()
  let waiter_result = process.new_subject()
  let server_worker =
    process.spawn_unlinked(fn() {
      let assert Ok(socket) = fake_server.accept_connection(server, 3000)
      let assert Ok(_) = fake_server.read_request_headers(socket, 3000)
      let _ =
        tcp.send(
          socket,
          bit_array.from_string(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n",
          ),
        )
      let release_server = process.new_subject()
      process.send(server_ready, release_server)
      let assert Ok(_) = process.receive(release_server, 4000)
      Nil
    })
  let prep = openai_prepared(server.port, "gpt-4o")
  let assert Ok(first_stream) =
    llm_wire.stream_with_pool(
      p,
      prep,
      llm_wire.default_limits(),
      llm_wire.default_deadlines(),
    )
  let assert Ok(release_server) = process.receive(server_ready, 2000)
  process.spawn_unlinked(fn() {
    process.send(
      waiter_result,
      llm_wire.run_with_pool(
        p,
        prep,
        llm_wire.default_limits(),
        types.Deadlines(3000, 3000, 3000),
      ),
    )
  })
  let assert True = wait_for_pool_waiters(p, 1, 100)
  let assert Ok(Nil) = llm_wire.stop_pool(p)
  let assert Ok(Error(types.TransportError("pool_stopped"))) =
    process.receive(waiter_result, 2000)
  let _ = owner.close(first_stream)
  process.send(release_server, Nil)
  let assert True = wait_for_process_exit(server_worker, 100)
  fake_server.stop(server)
}

fn wait_for_process_exit(pid: process.Pid, attempts: Int) -> Bool {
  case process.is_alive(pid) {
    False -> True
    True ->
      case attempts > 0 {
        True -> {
          process.sleep(10)
          wait_for_process_exit(pid, attempts - 1)
        }
        False -> False
      }
  }
}
