import conversation_fixture
import fake_server
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import llm_wire/config
import llm_wire/provider
import llm_wire/provider/anthropic as anthropic_provider
import llm_wire/provider/google as google_provider
import llm_wire/provider/openai as openai_provider
import llm_wire/session
import llm_wire/types
import tool_fixtures

fn local_config(port: Int) -> config.Config {
  let assert Ok(key) = types.api_key("sk-scripted")
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(port) <> "/v1")
  config.openai(openai_provider.options(key)) |> config.with_endpoint(endpoint)
}

fn request() -> types.Request {
  let assert Ok(model) = types.model_id("gpt-test")
  types.new_request(model, [types.UserMessage("calculate")])
  |> types.with_tools([tool_fixtures.int_field_tool("calc", "x")])
}

fn structured_terminal(
  stream: session.StructuredStream(Int),
) -> session.StructuredTerminal(Int) {
  case session.next_structured(stream) {
    Ok(session.StructuredNextProgress(_)) -> structured_terminal(stream)
    Ok(session.StructuredStreamTerminal(terminal)) -> terminal
    Error(_) -> {
      should.fail()
      structured_terminal(stream)
    }
  }
}

fn terminal(stream: session.Stream) -> session.Terminal {
  case session.next(stream) {
    Ok(session.NextProgress(_)) -> terminal(stream)
    Ok(session.StreamTerminal(outcome)) -> outcome
    Error(session.StreamReadError(types.ReadTimeout)) -> terminal(stream)
    Error(_) -> {
      should.fail()
      terminal(stream)
    }
  }
}

fn tool_events() -> String {
  "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"calc\"}}\n\n"
  <> "event: response.function_call_arguments.delta\ndata: {\"output_index\":0,\"item_id\":\"item_1\",\"delta\":\"{\\\"x\\\":42}\"}\n\n"
  <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\"}}\n\n"
  <> "event: response.completed\ndata: {\"response\":{\"id\":\"resp_1\",\"status\":\"completed\"}}\n\n"
}

pub fn configured_defaults_and_modifiers_keep_other_settings_test() {
  let assert Ok(key) = types.api_key("sk-test")
  let with_project =
    openai_provider.options(key)
    |> openai_provider.with_organization("org-test")
    |> openai_provider.with_project("proj-test")
    |> config.openai
  let assert Ok(prepared) = session.prepare(with_project, request())
  session.prepared_provider(prepared) |> should.equal(types.OpenAI)
  let adapter = config.adapter(with_project)
  let endpoint = provider.endpoint(adapter)
  list.contains(provider.headers(adapter), #("OpenAI-Organization", "org-test"))
  |> should.be_true
  list.contains(provider.headers(adapter), #("OpenAI-Project", "proj-test"))
  |> should.be_true
  types.endpoint_to_string(endpoint)
  |> should.equal("https://api.openai.com/v1")
  config.limits(with_project) |> should.equal(types.default_limits())
  config.deadlines(with_project) |> should.equal(types.default_deadlines())
  config.pool(with_project) |> should.equal(None)
}

pub fn all_provider_defaults_prepare_their_native_routes_test() {
  let assert Ok(key) = types.api_key("sk-test")
  let assert Ok(model) = types.model_id("model-test")
  let plain_request = types.new_request(model, [types.UserMessage("hello")])
  let assert Ok(openai) =
    session.prepare(config.openai(openai_provider.options(key)), plain_request)
  let assert Ok(anthropic) =
    session.prepare(
      config.anthropic(anthropic_provider.options(key)),
      plain_request,
    )
  let assert Ok(google) =
    session.prepare(config.google(google_provider.options(key)), plain_request)
  session.prepared_provider(openai) |> should.equal(types.OpenAI)
  session.prepared_provider(anthropic) |> should.equal(types.Anthropic)
  session.prepared_provider(google) |> should.equal(types.Google)
  let anthropic_endpoint =
    config.anthropic(anthropic_provider.options(key))
    |> config.adapter
    |> provider.endpoint
  let google_endpoint =
    config.google(google_provider.options(key))
    |> config.adapter
    |> provider.endpoint
  types.endpoint_to_string(anthropic_endpoint)
  |> should.equal("https://api.anthropic.com/v1")
  types.endpoint_to_string(google_endpoint)
  |> should.equal("https://generativelanguage.googleapis.com/v1beta")
}

pub fn configured_path_rejects_nonpositive_limits_and_deadlines_before_stream_test() {
  let settings = local_config(1)
  let bad_limits = types.Limits(..types.default_limits(), event_bytes_limit: 0)
  let bad_deadlines =
    types.Deadlines(..types.default_deadlines(), idle_timeout_ms: 0)
  case session.prepare(config.with_limits(settings, bad_limits), request()) {
    Error(types.ConfigurationError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
  case
    session.prepare(config.with_deadlines(settings, bad_deadlines), request())
  {
    Error(types.ConfigurationError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn outgoing_request_limit_is_independent_of_incoming_event_limit_test() {
  let base = local_config(1)
  let limits =
    types.Limits(
      ..types.default_limits(),
      event_bytes_limit: 16,
      request_bytes_limit: 4096,
    )
  let assert Ok(prepared) =
    session.prepare(config.with_limits(base, limits), request())
  let request_size = string.byte_size(session.prepared_request_json(prepared))
  let request_is_larger_than_event = request_size > limits.event_bytes_limit
  request_is_larger_than_event |> should.be_true
  let constrained =
    types.Limits(..limits, request_bytes_limit: request_size - 1)
  case session.prepare(config.with_limits(base, constrained), request()) {
    Error(types.ResourceLimitExceeded("request_bytes_limit", bound, measured)) -> {
      bound |> should.equal(request_size - 1)
      measured |> should.equal(request_size)
    }
    _ -> should.fail()
  }
}

pub fn configured_ca_rejects_plaintext_and_empty_path_at_prepare_test() {
  let plaintext =
    local_config(1)
    |> config.with_ca_cert_file("test/fixtures/llm-wire-test-ca.crt")
  case session.prepare(plaintext, request()) {
    Error(types.ConfigurationError(_)) -> should.be_true(True)
    _ -> should.fail()
  }

  let assert Ok(key) = types.api_key("sk-test")
  let empty =
    config.openai(openai_provider.options(key)) |> config.with_ca_cert_file("")
  case session.prepare(empty, request()) {
    Error(types.ConfigurationError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn caller_owned_buffered_round_applies_configured_limits_test() {
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_) = fake_server.read_request_headers(socket, 2000)
    let _ =
      fake_server.send_sse_stream(
        socket,
        [#(0, bit_array.from_string(tool_events()))],
        True,
      )
    Nil
  })
  let base = local_config(server.port)
  let assert Ok(unbounded) = session.prepare(base, request())
  let initial_bytes = string.byte_size(session.prepared_request_json(unbounded))
  let constrained_limits =
    types.Limits(
      ..types.default_limits(),
      request_bytes_limit: initial_bytes + 1,
    )
  let settings = config.with_limits(base, constrained_limits)
  let assert Ok(prepared) = session.prepare(settings, request())
  let assert Ok(session.RunToolCalls(turn, _)) = session.run(prepared)
  let assert [call] = turn.calls
  case
    session.prepare(
      settings,
      conversation_fixture.append_results(request(), turn, [
        types.ToolResult(call.id, "42"),
      ]),
    )
  {
    Error(types.ResourceLimitExceeded("request_bytes_limit", _, _)) ->
      should.be_true(True)
    _ -> should.fail()
  }
  fake_server.stop(server)
}

pub fn caller_owned_stream_round_applies_deadline_and_failure_evidence_test() {
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(first) = fake_server.accept_connection(server, 2000)
    let assert Ok(_) = fake_server.read_request_headers(first, 2000)
    let _ =
      fake_server.send_sse_stream(
        first,
        [#(0, bit_array.from_string(tool_events()))],
        True,
      )
    let assert Ok(second) = fake_server.accept_connection(server, 2000)
    let assert Ok(_) = fake_server.read_request_headers(second, 2000)
    let _ =
      fake_server.send_sse_stream(
        second,
        [
          #(
            500,
            bit_array.from_string(
              "event: response.completed\ndata: {\"response\":{\"id\":\"late\",\"status\":\"completed\"}}\n\n",
            ),
          ),
        ],
        True,
      )
    Nil
  })
  let deadlines =
    types.Deadlines(
      overall_timeout_ms: 200,
      idle_timeout_ms: 1000,
      read_timeout_ms: 50,
    )
  let settings = config.with_deadlines(local_config(server.port), deadlines)
  let assert Ok(prepared) = session.prepare(settings, request())
  let assert Ok(opened) = session.stream(prepared)
  let assert session.Finished(session.RunToolCalls(turn, _)) = terminal(opened)
  let assert [call] = turn.calls
  let assert Ok(next) =
    session.prepare(
      settings,
      conversation_fixture.append_results(request(), turn, [
        types.ToolResult(call.id, "42"),
      ]),
    )
  let assert Ok(resumed) = session.stream(next)
  let assert session.Failed(
    types.DeadlineExceeded(types.OverallDeadline),
    retry,
  ) = terminal(resumed)
  retry.classification |> should.equal(types.RequestMayHaveReachedProvider)
  fake_server.stop(server)
}

pub fn configured_refusal_keeps_usage_test() {
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_) = fake_server.read_request_headers(socket, 2000)
    let events =
      "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\"}}\n\n"
      <> "event: response.refusal.delta\ndata: {\"output_index\":0,\"item_id\":\"msg_1\",\"delta\":\"declined\"}\n\n"
      <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\"}}\n\n"
      <> "event: response.completed\ndata: {\"response\":{\"id\":\"resp_refusal\",\"status\":\"completed\",\"usage\":{\"input_tokens\":3,\"output_tokens\":2,\"total_tokens\":5}}}\n\n"
    let _ =
      fake_server.send_sse_stream(
        socket,
        [#(0, bit_array.from_string(events))],
        True,
      )
    Nil
  })
  let assert Ok(prepared) =
    session.prepare(local_config(server.port), request())
  session.run(prepared)
  |> should.equal(
    Ok(session.RunRefusal("declined", Some(types.Usage(3, 2, 5)))),
  )
  fake_server.stop(server)
}

pub fn caller_supplied_structured_codec_and_correlated_calls_test() {
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(first) = fake_server.accept_connection(server, 2000)
    let assert Ok(_) = fake_server.read_request_headers(first, 2000)
    let _ =
      fake_server.send_sse_stream(
        first,
        [#(0, bit_array.from_string(tool_events()))],
        True,
      )
    let assert Ok(second) = fake_server.accept_connection(server, 2000)
    let assert Ok(_) = fake_server.read_request_headers(second, 2000)
    let output_events =
      "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\"}}\n\n"
      <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"msg_1\",\"delta\":\"{\\\"answer\\\":42}\"}\n\n"
      <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\"}}\n\n"
      <> "event: response.completed\ndata: {\"response\":{\"id\":\"resp_2\",\"status\":\"completed\"}}\n\n"
    let _ =
      fake_server.send_sse_stream(
        second,
        [#(0, bit_array.from_string(output_events))],
        True,
      )
    Nil
  })
  let settings = local_config(server.port)
  let output_codec = codec.object(codec.required("answer", codec.int()))
  let assert Ok(prepared) =
    session.prepare_structured(
      settings,
      request(),
      "answer_shape",
      output_codec,
    )
  let assert Ok(opened) = session.stream_structured(prepared)
  let assert session.StructuredFinished(session.StructuredNeedsTools(turn, _)) =
    structured_terminal(opened)
  session.structured_request_json(prepared)
  |> string.contains("\"type\":\"json_schema\"")
  |> should.be_true
  let assert [call] = turn.calls
  let assert Ok(unknown_id) = types.call_id("other")
  let prepare_next = fn(results) {
    session.prepare_structured(
      settings,
      conversation_fixture.append_results(request(), turn, results),
      "answer_shape",
      output_codec,
    )
  }
  prepare_next([]) |> should.be_error
  prepare_next([
    types.ToolResult(unknown_id, "42"),
  ])
  |> should.be_error
  prepare_next([
    types.ToolResult(call.id, "42"),
    types.ToolResult(call.id, "42"),
  ])
  |> should.be_error
  let assert Ok(next) =
    prepare_next([
      types.ToolResult(call.id, "42"),
    ])
  session.structured_request_json(next)
  |> string.contains("\"type\":\"json_schema\"")
  |> should.be_true
  session.structured_request_json(next)
  |> string.contains("\"call_id\":\"call_1\"")
  |> should.be_true
  let assert Ok(session.StructuredValue(42, "{\"answer\":42}", _)) =
    session.run_structured(next)
  fake_server.stop(server)
}
