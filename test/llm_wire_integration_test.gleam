import fake_server
import gleam/bit_array
import gleam/erlang/process
import gleeunit/should
import llm_wire/client
import llm_wire/owner
import llm_wire/types

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
          "\"}\n\nevent: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"real TCP!\"}\n\n",
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
      "{}",
    )

  let assert Ok(types.NextProgress(types.ToolCallCompleted(call))) =
    owner.next(stream, 2000)
  types.call_id_to_string(call.id) |> should.equal("call_99")
  types.tool_name_to_string(call.name) |> should.equal("calc")
  call.arguments_json |> should.equal("{\"x\": 42}")

  let assert Ok(types.NextProgress(types.UsageUpdate(usage))) =
    owner.next(stream, 2000)
  usage.output_tokens |> should.equal(15)

  let assert Ok(types.StreamTerminal(types.StreamFinished(outcome, _))) =
    owner.next(stream, 2000)
  case outcome {
    types.CompletedToolCalls(_, calls) -> {
      calls |> should.equal([call])
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
      "{}",
    )

  case res {
    Error(types.HttpStatusError(429, body)) -> {
      body |> should.equal("{\"error\": \"rate_limited\"}")
    }
    _ -> panic as "expected HttpStatusError(429)"
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
      "{}",
    )

  case res {
    Error(types.TransportError(_)) -> Nil
    _ -> panic as "expected TransportError"
  }
}
