import conversation_fixture
import fake_server
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun/config as http_config
import http_gun/destination
import http_gun/error as http_error
import http_test_helpers
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/limit
import llm_wire/message
import llm_wire/openai
import llm_wire_test_client as client
import llm_wire_test_tcp as tcp
import mist
import tool_fixtures

fn local_endpoint(port: Int) -> String {
  "http://127.0.0.1:" <> int.to_string(port) <> "/v1"
}

fn openai_config(port: Int) -> llm_wire.Config {
  openai.new("sk-local-test")
  |> openai.config
  |> llm_wire.with_endpoint(local_endpoint(port))
}

fn anthropic_config(port: Int) -> llm_wire.Config {
  anthropic.new("sk-local-test")
  |> anthropic.config
  |> llm_wire.with_endpoint(local_endpoint(port))
}

fn serve(server: fake_server.FakeServer, chunks: List(#(Int, String))) -> Nil {
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)
    let _ =
      fake_server.send_sse_stream(
        socket,
        list.map(chunks, fn(chunk) {
          #(chunk.0, bit_array.from_string(chunk.1))
        }),
        True,
      )
    Nil
  })
  Nil
}

fn serve_raw(server: fake_server.FakeServer, raw: String) -> Nil {
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)
    let _ = fake_server.send_raw_response(socket, raw)
    Nil
  })
  Nil
}

/// Preparation admits plaintext host names. HTTP Gun refuses resolved
/// non-loopback addresses before sending.
pub fn api_rejects_remote_plaintext_before_transport_test() {
  let config =
    openai.new("sk-never-send")
    |> openai.config
    |> llm_wire.with_endpoint("http://api.example.test/v1")
  let assert Ok(prepared) =
    llm_wire.prepare(
      config,
      llm_wire.request("gpt-test", [llm_wire.user("hello")]),
    )
  let settings =
    http_config.default()
    |> http_config.with_resolver(fn(_host, _remaining) {
      Ok([destination.Ipv4(93, 184, 216, 34)])
    })
  use http <- http_test_helpers.with_settings(settings)
  let assert Error(failure) = llm_wire.run(http, prepared)
  let assert error.Http(http_failure) = failure.error
  http_error.reason(http_failure)
  |> should.equal(
    http_error.DestinationRejected(destination.PlaintextRefused(
      destination.Public,
    )),
  )
  failure.sent |> should.equal(llm_wire.NotSent)
}

pub fn caller_owned_assistant_turn_requires_exact_local_result_coverage_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  serve(server, [
    #(
      0,
      "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"calc\"}}\n\n",
    ),
    #(
      0,
      "event: response.function_call_arguments.delta\ndata: {\"output_index\":0,\"item_id\":\"item_1\",\"delta\":\"{\\\"x\\\":42}\"}\n\n",
    ),
    #(
      0,
      "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\"}}\n\n",
    ),
    #(
      0,
      "event: response.completed\ndata: {\"response\":{\"id\":\"resp_1\",\"status\":\"completed\"}}\n\n",
    ),
  ])

  let config = openai_config(server.port)
  let calc = tool_fixtures.int_field_tool("calc", "x")
  let request =
    llm_wire.request("gpt-test", [llm_wire.user("calculate")])
    |> llm_wire.with_tools([calc])
  let assert Ok(first_prepared) = llm_wire.prepare(config, request)

  let assert Ok(llm_wire.NeedsTools(turn:, issues: [], ..)) =
    llm_wire.run(owned_http, first_prepared)
  turn.response_id
  |> should.equal(Some("resp_1"))
  let assert [call] = turn.calls

  // Missing, duplicate and unknown result ids fail preparation.
  llm_wire.prepare(
    config,
    conversation_fixture.append_results(request, turn, []),
  )
  |> should_mismatch(call.id, error.MissingResult)
  llm_wire.prepare(
    config,
    conversation_fixture.append_results(request, turn, [
      #(call.id, "42"),
      #(call.id, "42"),
    ]),
  )
  |> should_mismatch(call.id, error.DuplicateResult)
  llm_wire.prepare(
    config,
    conversation_fixture.append_results(request, turn, [
      #("call_unknown", "42"),
    ]),
  )
  |> should_mismatch_problem(error.UnknownCall)

  // Preparing the same valid data twice is allowed: no origin-bound handle.
  let completed =
    conversation_fixture.append_results(request, turn, [#(call.id, "42")])
  llm_wire.prepare(config, completed) |> should.be_ok
  llm_wire.prepare(config, completed) |> should.be_ok
  fake_server.stop(server)
}

fn should_mismatch(
  prepared: Result(llm_wire.Prepared(o), error.PrepareError),
  call_id: String,
  problem: error.ResultProblem,
) -> Nil {
  let assert Error(error.ToolResultMismatch(id, found)) = prepared
  id |> should.equal(call_id)
  found |> should.equal(problem)
}

fn should_mismatch_problem(
  prepared: Result(llm_wire.Prepared(o), error.PrepareError),
  problem: error.ResultProblem,
) -> Nil {
  let assert Error(error.ToolResultMismatch(_, found)) = prepared
  found |> should.equal(problem)
}

pub fn anthropic_assistant_turn_preserves_typed_tool_use_input_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  serve(server, [
    #(
      0,
      "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-test\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n"
        <> "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"calc\"}}\n\n"
        <> "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"x\\\":42}\"}}\n\n"
        <> "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"
        <> "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":2}}\n\n"
        <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
    ),
  ])

  let config = anthropic_config(server.port)
  let calc = tool_fixtures.int_field_tool("calc", "x")
  let request =
    llm_wire.request("claude-test", [llm_wire.user("calculate")])
    |> llm_wire.with_tools([calc])
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
    llm_wire.run(owned_http, prepared)
  let assert [call] = turn.calls
  let assert Ok(follow_up) =
    llm_wire.prepare(
      config,
      conversation_fixture.append_results(request, turn, [
        #(call.id, "{\"result\":42}"),
      ]),
    )
  let body = llm_wire.request_json(follow_up)
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
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  serve(server, [
    #(
      0,
      "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\"}}\n\n",
    ),
    #(
      0,
      "event: response.refusal.delta\ndata: {\"output_index\":0,\"item_id\":\"msg_1\",\"delta\":\"I cannot help with that.\"}\n\n",
    ),
    #(
      0,
      "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\"}}\n\n",
    ),
    #(
      0,
      "event: response.completed\ndata: {\"response\":{\"id\":\"resp_refusal\",\"status\":\"completed\"}}\n\n",
    ),
  ])

  let assert Ok(prepared) =
    llm_wire.prepare(
      openai_config(server.port),
      llm_wire.request("gpt-test", [llm_wire.user("help")]),
    )
  llm_wire.run(owned_http, prepared)
  |> should.equal(Ok(llm_wire.Refused("I cannot help with that.", None)))
  fake_server.stop(server)
}

pub fn real_http_openai_streaming_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  serve(server, [
    #(
      10,
      "event: response.output_item.added\ndata: {\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\"}}\n\n",
    ),
    #(
      10,
      "event: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"Hello via ",
    ),
    #(
      10,
      "\"}\n\nevent: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"real TCP!\"}\n\nevent: response.output_item.done\ndata: {\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\", \"role\": \"assistant\"}}\n\n",
    ),
    #(
      10,
      "event: response.completed\ndata: {\"response\": {\"id\": \"r1\", \"status\": \"completed\", \"usage\": {\"input_tokens\": 5, \"output_tokens\": 4, \"total_tokens\": 9}}}\n\n",
    ),
  ])

  let assert Ok(stream) =
    client.open_openai_stream(owned_http, server.port, fn(c) { c }, [])

  let assert Ok(llm_wire.Progress(message.TextDelta(b1, t1))) =
    llm_wire.next(stream)
  b1 |> should.equal("item_1")
  t1 |> should.equal("Hello via ")

  let assert Ok(llm_wire.Progress(message.TextDelta(b2, t2))) =
    llm_wire.next(stream)
  b2 |> should.equal("item_1")
  t2 |> should.equal("real TCP!")

  let assert Ok(llm_wire.Progress(message.UsageUpdate(usage))) =
    llm_wire.next(stream)
  usage.total_tokens |> should.equal(9)

  let assert Ok(llm_wire.Done(Ok(llm_wire.Answer(text:, ..)))) =
    llm_wire.next(stream)
  text |> should.equal("Hello via real TCP!")

  fake_server.stop(server)
}

pub fn real_http_anthropic_streaming_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  serve(server, [
    #(
      10,
      "event: message_start\ndata: {\"type\": \"message_start\", \"message\": {\"id\": \"msg_tcp\", \"usage\": {\"input_tokens\": 10, \"output_tokens\": 1}}}\n\n",
    ),
    #(
      10,
      "event: content_block_start\ndata: {\"type\": \"content_block_start\", \"index\": 0, \"content_block\": {\"type\": \"tool_use\", \"id\": \"call_99\", \"name\": \"calc\"}}\n\n",
    ),
    #(
      10,
      "event: content_block_delta\ndata: {\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"input_json_delta\", \"partial_json\": \"{\\\"x\\\": 4",
    ),
    #(
      10,
      "2}\"}}\n\nevent: content_block_stop\ndata: {\"type\": \"content_block_stop\", \"index\": 0}\n\n",
    ),
    #(
      10,
      "event: message_delta\ndata: {\"type\": \"message_delta\", \"delta\": {\"stop_reason\": \"tool_use\"}, \"usage\": {\"output_tokens\": 15}}\n\n",
    ),
    #(10, "event: message_stop\ndata: {\"type\": \"message_stop\"}\n\n"),
  ])

  let assert Ok(stream) =
    client.open_anthropic_stream(owned_http, server.port, fn(c) { c }, [
      tool_fixtures.int_field_tool("calc", "x"),
    ])

  let #(progress, outcome) = read_all(stream, [])
  list.contains(progress, message.ToolArgumentsDelta("call_99", "{\"x\": 42}"))
  |> should.be_true
  let assert Ok(usage) =
    list.reverse(progress)
    |> list.find_map(fn(item) {
      case item {
        message.UsageUpdate(usage) -> Ok(usage)
        _ -> Error(Nil)
      }
    })
  usage.output_tokens |> should.equal(15)

  let assert Ok(llm_wire.NeedsTools(turn:, issues: [], ..)) = outcome
  turn.calls
  |> should.equal([
    message.ToolCall("call_99", "calc", "{\"x\": 42}", Some("call_99"), None),
  ])

  fake_server.stop(server)
}

fn read_all(
  stream: llm_wire.Stream(o),
  progress: List(message.Progress),
) -> #(List(message.Progress), Result(llm_wire.Outcome(o), llm_wire.Failure)) {
  let assert Ok(event) = llm_wire.next_within(stream, duration.seconds(5))
  case event {
    llm_wire.Progress(item) -> read_all(stream, [item, ..progress])
    llm_wire.Done(outcome) -> #(list.reverse(progress), outcome)
  }
}

pub fn real_http_error_response_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
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

  let res = client.open_openai_stream(owned_http, server.port, fn(c) { c }, [])

  let assert Error(failure) = opening_failure(res)
  failure.error
  |> should.equal(error.Status(
    429,
    "{\"error\": \"rate_limited\"}",
    Some(duration.seconds(3)),
  ))

  fake_server.stop(server)
}

pub fn buffered_http_status_failure_records_response_bytes_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_) = fake_server.read_request_headers(socket, 2000)
    let _ =
      fake_server.send_http_error(socket, 429, "Too Many Requests", "busy")
    Nil
  })
  let assert Ok(prepared) =
    llm_wire.prepare(
      openai_config(server.port),
      llm_wire.request("gpt-test", [llm_wire.user("hello")]),
    )
  let assert Error(failure) = llm_wire.run(owned_http, prepared)
  let assert error.Status(429, "busy", _) = failure.error
  // Completed means the provider finished its response, including an error status.
  failure.sent |> should.equal(llm_wire.Completed)
  fake_server.stop(server)
}

pub fn gun_refuses_redirects_instead_of_following_them_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  serve_raw(
    server,
    "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
  )
  let result =
    client.open_openai_stream(owned_http, server.port, fn(c) { c }, [])
  let assert Error(failure) = opening_failure(result)
  failure.error |> should.equal(error.Status(302, "", None))
  fake_server.stop(server)
}

pub fn gun_rejects_oversized_response_header_block_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  serve_raw(
    server,
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nX-Fill: "
      <> string.repeat("x", 17_000)
      <> "\r\nConnection: close\r\n\r\n",
  )
  let result =
    client.open_openai_stream(owned_http, server.port, fn(c) { c }, [])
  let assert Error(failure) = opening_failure(result)
  let assert error.Http(http_failure) = failure.error
  let assert http_error.LimitExceeded(http_error.ResponseHeaderBytes, _, _) =
    http_error.reason(http_failure)
  fake_server.stop(server)
}

pub fn gun_enforces_total_response_body_limit_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  serve(server, [#(0, string.repeat("x", 129))])
  let result =
    client.open_openai_stream(
      owned_http,
      server.port,
      llm_wire.with_limit(_, limit.ResponseBodyBytes, 128),
      [],
    )
  let assert Error(failure) = opening_failure(result)
  failure.error
  |> should.equal(error.LimitExceeded(limit.ResponseBodyBytes, 128, 129))
  fake_server.stop(server)
}

pub fn gun_decodes_chunked_transfer_before_sse_framing_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  let payload =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"chunked-item\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"chunked-item\",\"delta\":\"chunked\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"chunked-item\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"chunked-r\",\"status\":\"completed\"}}\n\n"
  serve_raw(
    server,
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
      <> int.to_base16(string.byte_size(payload))
      <> "\r\n"
      <> payload
      <> "\r\n0\r\n\r\n",
  )
  let assert Ok(stream) =
    client.open_openai_stream(owned_http, server.port, fn(c) { c }, [])
  let assert Ok(llm_wire.Progress(message.TextDelta("chunked-item", "chunked"))) =
    llm_wire.next(stream)
  let assert Ok(llm_wire.Done(Ok(llm_wire.Answer(text:, ..)))) =
    llm_wire.next(stream)
  text |> should.equal("chunked")
  fake_server.stop(server)
}

pub fn gun_rejects_compressed_event_streams_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  serve_raw(
    server,
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
  )
  let result =
    client.open_openai_stream(owned_http, server.port, fn(c) { c }, [])
  let assert Error(failure) = opening_failure(result)
  let assert error.Protocol(_) = failure.error
  fake_server.stop(server)
}

pub fn gun_setup_uses_remaining_overall_deadline_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)
    process.sleep(1500)
    let _ = tcp.close(socket)
    Nil
  })
  let configure = fn(config) {
    config
    |> llm_wire.with_call_timeout(llm_wire.After(duration.milliseconds(200)))
    |> llm_wire.with_first_token_timeout(llm_wire.After(duration.seconds(5)))
  }
  let result = client.open_openai_stream(owned_http, server.port, configure, [])
  let assert Error(failure) = opening_failure(result)
  failure.error |> should.equal(error.DeadlineExceeded(error.WholeCall))
  fake_server.stop(server)
}

pub fn real_http_disconnect_mid_stream_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  // A partial message, then the socket closes abruptly.
  serve(server, [
    #(
      10,
      "event: response.output_item.added\ndata: {\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\"}}\n\n",
    ),
    #(
      10,
      "event: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"Partial text\"}\n\n",
    ),
  ])

  let assert Ok(stream) =
    client.open_openai_stream(owned_http, server.port, fn(c) { c }, [])

  let assert Ok(llm_wire.Progress(message.TextDelta(..))) =
    llm_wire.next(stream)

  // Unexpected EOF retains uncertain send evidence and accepted semantic progress.
  let assert Ok(llm_wire.Done(Error(failure))) = llm_wire.next(stream)
  let assert error.Protocol(_) = failure.error
  failure.partial_output |> should.be_true
  failure.sent |> should.equal(llm_wire.MaybeSent)

  fake_server.stop(server)
}

fn start_tls_server(payload: String) -> #(process.Pid, Int) {
  let port_subject = process.new_subject()
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
  #(server.pid, port)
}

fn pinned_ca_settings() -> http_config.Config {
  http_test_helpers.loopback_config()
  |> http_config.with_trust(http_config.CustomCa(
    "test/fixtures/llm-wire-test-ca.crt",
  ))
}

pub fn gun_tls_stream_with_pinned_ca_test() {
  use owned_http <- http_test_helpers.with_settings(pinned_ca_settings())
  let payload =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"tls-item\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"tls-item\",\"delta\":\"trusted TLS\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"tls-item\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"tls-r1\",\"status\":\"completed\"}}\n\n"
  let #(server, port) = start_tls_server(payload)
  let assert Ok(stream) =
    client.open_stream(
      owned_http,
      message.OpenAI,
      "https",
      "127.0.0.1",
      port,
      "/v1",
      fn(c) { c },
      [],
    )

  let assert Ok(llm_wire.Progress(message.TextDelta("tls-item", text))) =
    llm_wire.next(stream)
  text |> should.equal("trusted TLS")
  let assert Ok(llm_wire.Done(Ok(llm_wire.Answer(text: "trusted TLS", ..)))) =
    llm_wire.next(stream)
  process.send_exit(server)
}

/// The client trusts the pinned CA; this fixture fails host-name verification.
pub fn gun_tls_rejects_hostname_mismatch_test() {
  use owned_http <- http_test_helpers.with_settings(
    pinned_ca_settings()
    |> http_config.with_resolver(fn(_host, _remaining) {
      Ok([destination.Ipv4(127, 0, 0, 1)])
    }),
  )
  let #(server, port) = start_tls_server("")
  let result =
    client.open_stream(
      owned_http,
      message.OpenAI,
      "https",
      "localhost",
      port,
      "/v1",
      fn(c) { c },
      [],
    )
  let assert Error(failure) = opening_failure(result)
  let assert error.Http(http_failure) = failure.error
  http_error.reason(http_failure)
  |> should.equal(http_error.ConnectionFailed(http_error.CertificateRejected))
  failure.sent |> should.equal(llm_wire.NotSent)
  process.send_exit(server)
}

pub fn gun_tls_rejects_untrusted_ca_test() {
  use owned_http <- http_test_helpers.with_client
  let #(server, port) = start_tls_server("")
  let result =
    client.open_stream(
      owned_http,
      message.OpenAI,
      "https",
      "127.0.0.1",
      port,
      "/v1",
      fn(c) { c },
      [],
    )
  let assert Error(failure) = opening_failure(result)
  let assert error.Http(http_failure) = failure.error
  http_error.reason(http_failure)
  |> should.equal(http_error.ConnectionFailed(http_error.CertificateRejected))
  failure.sent |> should.equal(llm_wire.NotSent)
  process.send_exit(server)
}

pub fn real_http_disconnect_before_bytes_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()

  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    // The connection closes without sending headers or bytes.
    let _ = fake_server.read_request_headers(socket, 2000)
    fake_server.stop(server)
    Nil
  })

  let res = client.open_openai_stream(owned_http, server.port, fn(c) { c }, [])

  let assert Error(failure) = opening_failure(res)
  let assert error.Http(_) = failure.error
  failure.sent |> should.equal(llm_wire.MaybeSent)
}

/// The failure that ends a stream before any progress.
fn opening_failure(
  opened: Result(llm_wire.Stream(String), llm_wire.Failure),
) -> Result(Nil, llm_wire.Failure) {
  case opened {
    Error(failure) -> Error(failure)
    Ok(stream) ->
      case llm_wire.next_within(stream, duration.seconds(5)) {
        Ok(llm_wire.Done(Error(failure))) -> Error(failure)
        other -> panic as string.inspect(other)
      }
  }
}
