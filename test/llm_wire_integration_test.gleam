import fake_server
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import llm_wire/api
import llm_wire/internal/client as prepared_client
import llm_wire/owner
import llm_wire/runtime
import llm_wire/tcp
import llm_wire/types
import llm_wire_test_client as client
import mist
import tool_fixtures

pub fn api_rejects_remote_plaintext_before_transport_test() {
  let assert Ok(api_key) = types.api_key("sk-never-send")
  let assert Ok(endpoint) = types.endpoint("http://api.example.test/v1")
  let config = types.openai_config(api_key, endpoint, None, None)
  let assert Ok(model) = types.model_id("gpt-test")
  let request = types.new_request(model, [types.UserMessage("hello")])
  case api.prepare(config, request, types.default_limits()) {
    Error(types.ConfigurationError(reason)) ->
      reason
      |> should.equal(
        "Endpoint must use HTTPS (HTTP is allowed only for loopback tests) and a valid host/port",
      )
    _ -> should.fail()
  }
}

pub fn prepared_client_rejects_caller_ca_for_remote_host_test() {
  let assert Ok(api_key) = types.api_key("sk-never-send")
  let assert Ok(endpoint) = types.endpoint("https://api.example.test/v1")
  let assert Ok(model) = types.model_id("gpt-test")
  let config = types.openai_config(api_key, endpoint, None, None)
  let request = types.new_request(model, [types.UserMessage("hello")])
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  case
    prepared_client.open_prepared_stream(
      prepared,
      types.default_limits(),
      types.default_deadlines(),
      Some(types.VerifyCaFile("test/fixtures/llm-wire-test-ca.crt")),
    )
  {
    Error(types.ConfigurationError(reason)) ->
      reason
      |> should.equal(
        "Client requires valid HTTP fields; remote hosts require system-verified HTTPS",
      )
    _ -> should.fail()
  }
}

pub fn continuation_is_opaque_and_bound_to_its_prepared_interaction_test() {
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)
    let chunks = [
      #(
        0,
        bit_array.from_string(
          "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"calc\"}}\n\n",
        ),
      ),
      #(
        0,
        bit_array.from_string(
          "event: response.function_call_arguments.delta\ndata: {\"output_index\":0,\"item_id\":\"item_1\",\"delta\":\"{\\\"x\\\":42}\"}\n\n",
        ),
      ),
      #(
        0,
        bit_array.from_string(
          "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\"}}\n\n",
        ),
      ),
      #(
        0,
        bit_array.from_string(
          "event: response.completed\ndata: {\"response\":{\"id\":\"resp_1\",\"status\":\"completed\"}}\n\n",
        ),
      ),
    ]
    let _ = fake_server.send_sse_stream(socket, chunks, True)
    Nil
  })

  let assert Ok(key) = types.api_key("sk-local-test")
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(server.port) <> "/v1")
  let assert Ok(model) = types.model_id("gpt-test")
  let config = types.openai_config(key, endpoint, None, None)
  let tool = tool_fixtures.int_field_tool("calc", "x")
  let request =
    types.new_request(model, [types.UserMessage("calculate")])
    |> types.with_tools([tool])
  let assert Ok(first_prepared) =
    api.prepare(config, request, types.default_limits())
  let assert Ok(second_prepared) =
    api.prepare(config, request, types.default_limits())

  let assert Ok(api.RunToolCalls(calls, continuation, _usage)) =
    runtime.run(
      first_prepared,
      types.default_limits(),
      types.default_deadlines(),
    )
  api.continuation_response_id(continuation)
  |> should.equal(Some("resp_1"))
  let assert [call] = calls
  let assert Ok(unknown_id) = types.call_id("call_unknown")
  let results = [types.ToolResult(call.id, "42")]

  api.prepare_continue(first_prepared, continuation, [], types.default_limits())
  |> should.be_error
  api.prepare_continue(
    first_prepared,
    continuation,
    [types.ToolResult(call.id, "42"), types.ToolResult(call.id, "42")],
    types.default_limits(),
  )
  |> should.be_error
  api.prepare_continue(
    first_prepared,
    continuation,
    [types.ToolResult(unknown_id, "42")],
    types.default_limits(),
  )
  |> should.be_error

  api.prepare_continue(
    second_prepared,
    continuation,
    results,
    types.default_limits(),
  )
  |> should.be_error

  api.prepare_continue(
    first_prepared,
    continuation,
    results,
    types.default_limits(),
  )
  |> should.be_ok
  fake_server.stop(server)
}

pub fn anthropic_continuation_restores_typed_tool_use_input_test() {
  let assert Ok(server) = fake_server.start()
  let stream =
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n"
    <> "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"calc\"}}\n\n"
    <> "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"x\\\":42}\"}}\n\n"
    <> "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
    <> "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":2}}\n\n"
    <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_) = fake_server.read_request_headers(socket, 2000)
    let _ =
      fake_server.send_sse_stream(
        socket,
        [#(0, bit_array.from_string(stream))],
        True,
      )
    Nil
  })

  let assert Ok(key) = types.api_key("sk-local-test")
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(server.port) <> "/v1")
  let assert Ok(model) = types.model_id("claude-test")
  let config = types.anthropic_config(key, endpoint, None)
  let tool = tool_fixtures.int_field_tool("calc", "x")
  let request =
    types.new_request(model, [types.UserMessage("calculate")])
    |> types.with_tools([tool])
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  let assert Ok(api.RunToolCalls([call], continuation, _)) =
    runtime.run(prepared, types.default_limits(), types.default_deadlines())
  let assert Ok(follow_up) =
    api.prepare_continue(
      prepared,
      continuation,
      [types.ToolResult(call.id, "{\"result\":42}")],
      types.default_limits(),
    )
  let body = api.prepared_request_json(follow_up)
  string.contains(body, "\"role\":\"assistant\"")
  |> should.equal(True)
  string.contains(
    body,
    "\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"calc\",\"input\":{\"x\":42}",
  )
  |> should.equal(True)
  string.contains(
    body,
    "\"type\":\"tool_result\",\"tool_use_id\":\"toolu_1\",\"content\":\"{\\\"result\\\":42}\"",
  )
  |> should.equal(True)
  fake_server.stop(server)
}

pub fn buffered_api_preserves_openai_refusal_outcome_test() {
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)
    let chunks = [
      #(
        0,
        bit_array.from_string(
          "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\"}}\n\n",
        ),
      ),
      #(
        0,
        bit_array.from_string(
          "event: response.refusal.delta\ndata: {\"output_index\":0,\"item_id\":\"msg_1\",\"delta\":\"I cannot help with that.\"}\n\n",
        ),
      ),
      #(
        0,
        bit_array.from_string(
          "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\"}}\n\n",
        ),
      ),
      #(
        0,
        bit_array.from_string(
          "event: response.completed\ndata: {\"response\":{\"id\":\"resp_refusal\",\"status\":\"completed\"}}\n\n",
        ),
      ),
    ]
    let _ = fake_server.send_sse_stream(socket, chunks, True)
    Nil
  })

  let assert Ok(key) = types.api_key("sk-local-test")
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(server.port) <> "/v1")
  let assert Ok(model) = types.model_id("gpt-test")
  let config = types.openai_config(key, endpoint, None, None)
  let request = types.new_request(model, [types.UserMessage("help")])
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())

  runtime.run(prepared, types.default_limits(), types.default_deadlines())
  |> should.equal(Ok(api.RunRefusal("I cannot help with that.")))
  fake_server.stop(server)
}

pub fn real_http_openai_streaming_test() {
  let assert Ok(server) = fake_server.start()
  let port = server.port

  // Spawn background server worker
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)

    let chunks = [
      #(
        10,
        bit_array.from_string(
          "event: response.output_item.added\ndata: {\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\"}}\n\n",
        ),
      ),
      #(
        10,
        bit_array.from_string(
          "event: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"Hello via ",
        ),
      ),
      #(
        10,
        bit_array.from_string(
          "\"}\n\nevent: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"real TCP!\"}\n\nevent: response.output_item.done\ndata: {\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\", \"role\": \"assistant\"}}\n\n",
        ),
      ),
      #(
        10,
        bit_array.from_string(
          "event: response.completed\ndata: {\"response\": {\"id\": \"r1\", \"status\": \"completed\", \"usage\": {\"input_tokens\": 5, \"output_tokens\": 4, \"total_tokens\": 9}}}\n\n",
        ),
      ),
    ]

    let _ = fake_server.send_sse_stream(socket, chunks, True)
    Nil
  })

  let assert Ok(api_key) = types.api_key("sk-fake-test-key")
  let limits = types.default_limits()
  let deadlines = types.default_deadlines()

  let assert Ok(stream) =
    client.open_openai_stream(
      "127.0.0.1",
      port,
      "/v1/responses",
      api_key,
      limits,
      deadlines,
      [],
      "{}",
    )

  let assert Ok(types.NextProgress(types.TextDelta(b1, t1))) =
    owner.next(stream, 2000)
  b1 |> should.equal("item_1")
  t1 |> should.equal("Hello via ")

  let assert Ok(types.NextProgress(types.TextDelta(b2, t2))) =
    owner.next(stream, 2000)
  b2 |> should.equal("item_1")
  t2 |> should.equal("real TCP!")

  let assert Ok(types.NextProgress(types.UsageUpdate(usage))) =
    owner.next(stream, 2000)
  usage.total_tokens |> should.equal(9)

  let assert Ok(types.StreamTerminal(types.StreamFinished(outcome, _))) =
    owner.next(stream, 2000)
  outcome |> should.equal(types.CompletedText("Hello via real TCP!"))

  fake_server.stop(server)
}

pub fn real_http_anthropic_streaming_test() {
  let assert Ok(server) = fake_server.start()
  let port = server.port

  // Spawn background server worker
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)

    let chunks = [
      #(
        10,
        bit_array.from_string(
          "event: message_start\ndata: {\"type\": \"message_start\", \"message\": {\"id\": \"msg_tcp\", \"usage\": {\"input_tokens\": 10, \"output_tokens\": 1}}}\n\n",
        ),
      ),
      #(
        10,
        bit_array.from_string(
          "event: content_block_start\ndata: {\"type\": \"content_block_start\", \"index\": 0, \"content_block\": {\"type\": \"tool_use\", \"id\": \"call_99\", \"name\": \"calc\"}}\n\n",
        ),
      ),
      #(
        10,
        bit_array.from_string(
          "event: content_block_delta\ndata: {\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"input_json_delta\", \"partial_json\": \"{\\\"x\\\": 4",
        ),
      ),
      #(
        10,
        bit_array.from_string(
          "2}\"}}\n\nevent: content_block_stop\ndata: {\"type\": \"content_block_stop\", \"index\": 0}\n\n",
        ),
      ),
      #(
        10,
        bit_array.from_string(
          "event: message_delta\ndata: {\"type\": \"message_delta\", \"delta\": {\"stop_reason\": \"tool_use\"}, \"usage\": {\"output_tokens\": 15}}\n\n",
        ),
      ),
      #(
        10,
        bit_array.from_string(
          "event: message_stop\ndata: {\"type\": \"message_stop\"}\n\n",
        ),
      ),
    ]

    let _ = fake_server.send_sse_stream(socket, chunks, True)
    Nil
  })

  let assert Ok(api_key) = types.api_key("sk-ant-test-key")
  let limits = types.default_limits()
  let deadlines = types.default_deadlines()

  let assert Ok(stream) =
    client.open_anthropic_stream(
      "127.0.0.1",
      port,
      "/v1/messages",
      api_key,
      limits,
      deadlines,
      [tool_fixtures.int_field_tool("calc", "x")],
      "{}",
    )

  let assert Ok(types.NextProgress(types.UsageUpdate(usage))) =
    owner.next(stream, 2000)
  usage.output_tokens |> should.equal(15)

  let assert Ok(types.StreamTerminal(types.StreamFinished(outcome, _))) =
    owner.next(stream, 2000)
  let assert Ok(call_id) = types.call_id("call_99")
  let assert Ok(tool_name) = types.tool_name("calc")
  case outcome {
    types.CompletedToolCalls(_, calls, _response_id) -> {
      calls
      |> should.equal([
        types.ToolCall(call_id, tool_name, "{\"x\": 42}", Some("call_99")),
      ])
    }
    _ -> panic as "expected CompletedToolCalls"
  }

  fake_server.stop(server)
}

pub fn real_http_error_response_test() {
  let assert Ok(server) = fake_server.start()
  let port = server.port

  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)
    let _ =
      fake_server.send_http_error(
        socket,
        429,
        "Too Many Requests",
        "{\"error\": \"rate_limited\"}",
      )
    Nil
  })

  let assert Ok(api_key) = types.api_key("sk-test")
  let limits = types.default_limits()
  let deadlines = types.default_deadlines()

  let res =
    client.open_openai_stream(
      "127.0.0.1",
      port,
      "/v1/responses",
      api_key,
      limits,
      deadlines,
      [],
      "{}",
    )

  case res {
    Error(types.HttpStatusError(429, body, Some(types.RetryDelaySeconds(3)))) -> {
      body |> should.equal("{\"error\": \"rate_limited\"}")
    }
    _ -> panic as "expected HttpStatusError(429)"
  }

  fake_server.stop(server)
}

pub fn gun_refuses_redirects_instead_of_following_them_test() {
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)
    let _ =
      fake_server.send_raw_response(
        socket,
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
      )
    Nil
  })
  let assert Ok(api_key) = types.api_key("sk-test")
  let result =
    client.open_openai_stream(
      "127.0.0.1",
      server.port,
      "/v1/responses",
      api_key,
      types.default_limits(),
      types.default_deadlines(),
      [],
      "{}",
    )
  case result {
    Error(types.HttpStatusError(302, "", None)) -> should.be_true(True)
    _ -> should.fail()
  }
  fake_server.stop(server)
}

pub fn gun_rejects_oversized_response_header_block_test() {
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)
    let response =
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nX-Fill: "
      <> string.repeat("x", 17_000)
      <> "\r\nConnection: close\r\n\r\n"
    let _ = fake_server.send_raw_response(socket, response)
    Nil
  })
  let assert Ok(api_key) = types.api_key("sk-test")
  let result =
    client.open_openai_stream(
      "127.0.0.1",
      server.port,
      "/v1/responses",
      api_key,
      types.default_limits(),
      types.default_deadlines(),
      [],
      "{}",
    )
  case result {
    Error(types.TransportError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
  fake_server.stop(server)
}

pub fn gun_enforces_total_response_body_limit_test() {
  let assert Ok(server) = fake_server.start()
  let limits =
    types.Limits(..types.default_limits(), response_body_bytes_limit: 128)
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)
    let _ =
      fake_server.send_sse_stream(
        socket,
        [#(0, bit_array.from_string(string.repeat("x", 129)))],
        True,
      )
    Nil
  })
  let assert Ok(api_key) = types.api_key("sk-test")
  let assert Ok(stream) =
    client.open_openai_stream(
      "127.0.0.1",
      server.port,
      "/v1/responses",
      api_key,
      limits,
      types.default_deadlines(),
      [],
      "{}",
    )
  case owner.next(stream, 2000) {
    Ok(types.StreamTerminal(types.StreamFailed(
      types.ResourceLimitExceeded("response_body_bytes_limit", 128, 129),
      _,
    ))) -> should.be_true(True)
    _ -> should.fail()
  }
  fake_server.stop(server)
}

pub fn gun_decodes_chunked_transfer_before_sse_framing_test() {
  let assert Ok(server) = fake_server.start()
  let payload =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"chunked-item\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"chunked-item\",\"delta\":\"chunked\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"chunked-item\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"chunked-r\",\"status\":\"completed\"}}\n\n"
  let wire_response =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
    <> int.to_base16(string.byte_size(payload))
    <> "\r\n"
    <> payload
    <> "\r\n0\r\n\r\n"
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)
    let _ = fake_server.send_raw_response(socket, wire_response)
    Nil
  })
  let assert Ok(api_key) = types.api_key("sk-test")
  let assert Ok(stream) =
    client.open_openai_stream(
      "127.0.0.1",
      server.port,
      "/v1/responses",
      api_key,
      types.default_limits(),
      types.default_deadlines(),
      [],
      "{}",
    )
  let assert Ok(types.NextProgress(types.TextDelta("chunked-item", "chunked"))) =
    owner.next(stream, 2000)
  let assert Ok(types.StreamTerminal(types.StreamFinished(outcome, _))) =
    owner.next(stream, 2000)
  outcome |> should.equal(types.CompletedText("chunked"))
  fake_server.stop(server)
}

pub fn gun_rejects_compressed_event_streams_test() {
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)
    let _ =
      fake_server.send_raw_response(
        socket,
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
      )
    Nil
  })
  let assert Ok(api_key) = types.api_key("sk-test")
  let result =
    client.open_openai_stream(
      "127.0.0.1",
      server.port,
      "/v1/responses",
      api_key,
      types.default_limits(),
      types.default_deadlines(),
      [],
      "{}",
    )
  case result {
    Error(types.TransportError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
  fake_server.stop(server)
}

pub fn gun_setup_uses_remaining_overall_deadline_test() {
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)
    process.sleep(250)
    let _ = tcp.close(socket)
    Nil
  })
  let assert Ok(api_key) = types.api_key("sk-test")
  let assert Ok(deadlines) =
    types.new_deadlines(
      overall_timeout_ms: 75,
      idle_timeout_ms: 5000,
      read_timeout_ms: 100,
    )
  let result =
    client.open_openai_stream(
      "127.0.0.1",
      server.port,
      "/v1/responses",
      api_key,
      types.default_limits(),
      deadlines,
      [],
      "{}",
    )
  case result {
    Error(types.TransportError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
  fake_server.stop(server)
}

pub fn real_http_disconnect_mid_stream_test() {
  let assert Ok(server) = fake_server.start()
  let port = server.port

  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)

    // Send partial message, then close socket abruptly!
    let chunks = [
      #(
        10,
        bit_array.from_string(
          "event: response.output_item.added\ndata: {\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\"}}\n\n",
        ),
      ),
      #(
        10,
        bit_array.from_string(
          "event: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"Partial text\"}\n\n",
        ),
      ),
    ]
    let _ = fake_server.send_sse_stream(socket, chunks, True)
    Nil
  })

  let assert Ok(api_key) = types.api_key("sk-test")
  let limits = types.default_limits()
  let deadlines = types.default_deadlines()

  let assert Ok(stream) =
    client.open_openai_stream(
      "127.0.0.1",
      port,
      "/v1/responses",
      api_key,
      limits,
      deadlines,
      [],
      "{}",
    )

  let assert Ok(types.NextProgress(types.TextDelta(..))) =
    owner.next(stream, 2000)

  // Next read should be terminal error due to unexpected EOF
  let res = owner.next(stream, 2000)
  case res {
    Ok(types.StreamTerminal(types.StreamFailed(
      types.ProtocolError(_),
      retry_evidence,
    ))) -> {
      retry_evidence.response_bytes_observed |> should.equal(True)
      retry_evidence.semantic_progress_observed |> should.equal(True)
    }
    _ -> panic as "expected ProtocolError terminal with retry evidence"
  }

  fake_server.stop(server)
}

pub fn gun_tls_stream_with_pinned_ca_test() {
  let port_subject = process.new_subject()
  let payload =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"tls-item\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"tls-item\",\"delta\":\"trusted TLS\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"tls-item\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"tls-r1\",\"status\":\"completed\"}}\n\n"
  let handler = fn(_request) {
    response.new(200)
    |> response.set_header("content-type", "text/event-stream")
    |> response.set_header("cache-control", "no-cache")
    |> response.set_body(mist.Bytes(bytes_tree.from_string(payload)))
  }
  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.with_tls(
      "test/fixtures/loopback-test.crt",
      "test/fixtures/loopback-test.key",
    )
    |> mist.after_start(fn(port, _scheme, _interface) {
      process.send(port_subject, port)
    })
    |> mist.start
  let assert Ok(port) = process.receive(port_subject, 2000)
  let assert Ok(api_key) = types.api_key("sk-local-tls-test")

  let assert Ok(stream) =
    client.open_openai_stream_with_tls_mode(
      "127.0.0.1",
      port,
      "/v1/responses",
      api_key,
      types.default_limits(),
      types.default_deadlines(),
      [],
      "{}",
      types.VerifyCaFile("test/fixtures/llm-wire-test-ca.crt"),
    )

  let assert Ok(types.NextProgress(types.TextDelta("tls-item", text))) =
    owner.next(stream, 2000)
  text |> should.equal("trusted TLS")
  let assert Ok(types.StreamTerminal(types.StreamFinished(outcome, _))) =
    owner.next(stream, 2000)
  outcome |> should.equal(types.CompletedText("trusted TLS"))
  process.send_exit(server.pid)
}

pub fn gun_tls_rejects_hostname_mismatch_test() {
  let port_subject = process.new_subject()
  let handler = fn(_request) {
    response.new(200)
    |> response.set_header("content-type", "text/event-stream")
    |> response.set_body(mist.Bytes(bytes_tree.from_string("")))
  }
  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.with_tls(
      "test/fixtures/loopback-test.crt",
      "test/fixtures/loopback-test.key",
    )
    |> mist.after_start(fn(port, _scheme, _interface) {
      process.send(port_subject, port)
    })
    |> mist.start
  let assert Ok(port) = process.receive(port_subject, 2000)
  let assert Ok(api_key) = types.api_key("sk-local-tls-test")
  let result =
    client.open_openai_stream_with_tls_mode(
      "localhost",
      port,
      "/v1/responses",
      api_key,
      types.default_limits(),
      types.default_deadlines(),
      [],
      "{}",
      types.VerifyCaFile("test/fixtures/llm-wire-test-ca.crt"),
    )
  case result {
    Error(types.TransportError(_)) -> Nil
    _ -> panic as "expected certificate hostname verification failure"
  }
  process.send_exit(server.pid)
}

pub fn gun_tls_rejects_untrusted_ca_test() {
  let port_subject = process.new_subject()
  let handler = fn(_request) {
    response.new(200)
    |> response.set_header("content-type", "text/event-stream")
    |> response.set_body(mist.Bytes(bytes_tree.from_string("")))
  }
  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.with_tls(
      "test/fixtures/loopback-test.crt",
      "test/fixtures/loopback-test.key",
    )
    |> mist.after_start(fn(port, _scheme, _interface) {
      process.send(port_subject, port)
    })
    |> mist.start
  let assert Ok(port) = process.receive(port_subject, 2000)
  let assert Ok(api_key) = types.api_key("sk-local-tls-test")
  let result =
    client.open_openai_stream_with_tls_mode(
      "127.0.0.1",
      port,
      "/v1/responses",
      api_key,
      types.default_limits(),
      types.default_deadlines(),
      [],
      "{}",
      types.VerifySystem,
    )
  case result {
    Error(types.TransportError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
  process.send_exit(server.pid)
}

pub fn real_http_disconnect_before_bytes_test() {
  let assert Ok(server) = fake_server.start()
  let port = server.port

  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    // Close socket immediately without sending headers or bytes
    let _ = fake_server.read_request_headers(socket, 2000)
    fake_server.stop(server)
    Nil
  })

  let assert Ok(api_key) = types.api_key("sk-test")
  let limits = types.default_limits()
  let deadlines = types.default_deadlines()

  let res =
    client.open_openai_stream(
      "127.0.0.1",
      port,
      "/v1/responses",
      api_key,
      limits,
      deadlines,
      [],
      "{}",
    )

  case res {
    Error(types.TransportError(_)) -> Nil
    _ -> panic as "expected TransportError"
  }
}
