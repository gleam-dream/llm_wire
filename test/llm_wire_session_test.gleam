//// The run/stream execution family over caller-owned HTTP Gun clients.
//// `llm_wire/session` and `llm_wire/config` became the `llm_wire` facade.

import conversation_fixture
import fake_server
import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun/testing as http_testing
import http_test_helpers
import json/blueprint/codec
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/google
import llm_wire/internal/api
import llm_wire/internal/call
import llm_wire/internal/config
import llm_wire/internal/limits
import llm_wire/limit
import llm_wire/message
import llm_wire/openai
import llm_wire/testing
import tool_fixtures

fn local_config(port: Int) -> llm_wire.Config {
  openai.new("sk-scripted")
  |> openai.config
  |> llm_wire.with_endpoint("http://127.0.0.1:" <> int.to_string(port) <> "/v1")
}

fn request() -> llm_wire.Request(String) {
  llm_wire.request("gpt-test", [llm_wire.user("calculate")])
  |> llm_wire.with_tools([tool_fixtures.int_field_tool("calc", "x")])
}

/// The HTTP request a prepared call sends, as HTTP Gun records it.
fn sent_request(prepared: llm_wire.Prepared(o)) {
  http_testing.request(testing.exchange(prepared, testing.text("")))
}

fn provider_of(prepared: llm_wire.Prepared(o)) -> message.Provider {
  api.provider(call.prepared_call(prepared))
}

/// Read a stream to its end, skipping progress.
fn terminal(
  stream: llm_wire.Stream(o),
) -> Result(llm_wire.Outcome(o), llm_wire.Failure) {
  case llm_wire.next(stream) {
    Ok(llm_wire.Progress(_)) -> terminal(stream)
    Ok(llm_wire.Done(result)) -> result
    Error(read_error) ->
      panic as { "read failed: " <> string.inspect(read_error) }
  }
}

fn tool_events() -> String {
  "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\"calc\"}}\n\n"
  <> "event: response.function_call_arguments.delta\ndata: {\"output_index\":0,\"item_id\":\"item_1\",\"delta\":\"{\\\"x\\\":42}\"}\n\n"
  <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\"}}\n\n"
  <> "event: response.completed\ndata: {\"response\":{\"id\":\"resp_1\",\"status\":\"completed\"}}\n\n"
}

pub fn configured_defaults_and_modifiers_keep_other_settings_test() {
  let with_project =
    openai.new("sk-test")
    |> openai.with_organization("org-test")
    |> openai.with_project("proj-test")
    |> openai.config
  let assert Ok(prepared) = llm_wire.prepare(with_project, request())
  provider_of(prepared) |> should.equal(message.OpenAI)
  // `provider.reveal_headers` is gone; the admitted request shows the
  // provider headers, with lowercase names.
  let sent = sent_request(prepared)
  list.contains(sent.headers, #("openai-organization", "org-test"))
  |> should.be_true
  list.contains(sent.headers, #("openai-project", "proj-test"))
  |> should.be_true
  sent.scheme |> should.equal(http.Https)
  sent.host |> should.equal("api.openai.com")
  sent.path |> should.equal("/v1/responses")
  config.limits(with_project) |> should.equal(limits.default())
  config.timeouts(with_project) |> should.equal(config.default_timeouts())
}

pub fn all_provider_defaults_prepare_their_native_routes_test() {
  let plain_request = llm_wire.request("model-test", [llm_wire.user("hello")])
  let assert Ok(openai_call) =
    llm_wire.prepare(openai.new("sk-test") |> openai.config, plain_request)
  let assert Ok(anthropic_call) =
    llm_wire.prepare(
      anthropic.new("sk-test") |> anthropic.config,
      plain_request,
    )
  let assert Ok(google_call) =
    llm_wire.prepare(google.new("sk-test") |> google.config, plain_request)
  provider_of(openai_call) |> should.equal(message.OpenAI)
  provider_of(anthropic_call) |> should.equal(message.Anthropic)
  provider_of(google_call) |> should.equal(message.Google)
  // Endpoints are plain strings now; the default shows in the request.
  let anthropic_sent = sent_request(anthropic_call)
  anthropic_sent.host |> should.equal("api.anthropic.com")
  anthropic_sent.path |> should.equal("/v1/messages")
  let google_sent = sent_request(google_call)
  google_sent.host |> should.equal("generativelanguage.googleapis.com")
  string.starts_with(google_sent.path, "/v1beta/") |> should.be_true
}

pub fn configured_path_rejects_nonpositive_limits_and_deadlines_before_stream_test() {
  let settings = local_config(1)
  let assert Error(error.InvalidSetting(error.LimitSetting(limit.EventBytes), _)) =
    llm_wire.prepare(
      llm_wire.with_limit(settings, limit.EventBytes, 0),
      request(),
    )
  let assert Error(error.InvalidSetting(error.TimeoutSetting(error.IdleGap), _)) =
    llm_wire.prepare(
      llm_wire.with_idle_timeout(
        settings,
        llm_wire.After(duration.milliseconds(0)),
      ),
      request(),
    )
}

pub fn outgoing_request_limit_is_independent_of_incoming_event_limit_test() {
  let base =
    local_config(1)
    |> llm_wire.with_limit(limit.EventBytes, 16)
    |> llm_wire.with_limit(limit.RequestBytes, 4096)
  let assert Ok(prepared) = llm_wire.prepare(base, request())
  let request_size = string.byte_size(llm_wire.request_json(prepared))
  { request_size > 16 } |> should.be_true
  let constrained =
    llm_wire.with_limit(base, limit.RequestBytes, request_size - 1)
  llm_wire.prepare(constrained, request())
  |> should.equal(
    Error(error.RequestTooLarge(
      limit.RequestBytes,
      request_size - 1,
      request_size,
    )),
  )
}

pub fn caller_owned_buffered_round_applies_configured_limits_test() {
  use owned_http <- http_test_helpers.with_client
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
  let assert Ok(unbounded) = llm_wire.prepare(base, request())
  let initial_bytes = string.byte_size(llm_wire.request_json(unbounded))
  let settings =
    llm_wire.with_limit(base, limit.RequestBytes, initial_bytes + 1)
  let assert Ok(prepared) = llm_wire.prepare(settings, request())
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
    llm_wire.run(owned_http, prepared)
  let assert [first_call] = turn.calls
  let assert Error(error.RequestTooLarge(limit.RequestBytes, _, _)) =
    llm_wire.prepare(
      settings,
      conversation_fixture.append_results(request(), turn, [
        #(first_call.id, "42"),
      ]),
    )
  fake_server.stop(server)
}

pub fn caller_owned_stream_round_applies_deadline_and_failure_evidence_test() {
  use owned_http <- http_test_helpers.with_client
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
  // The overall deadline is the whole-call timeout; the read deadline is
  // gone, since `next` waits for the next event.
  let settings =
    local_config(server.port)
    |> llm_wire.with_call_timeout(llm_wire.After(duration.milliseconds(200)))
    |> llm_wire.with_idle_timeout(llm_wire.After(duration.milliseconds(1000)))
  let assert Ok(prepared) = llm_wire.prepare(settings, request())
  let assert Ok(opened) = llm_wire.stream(owned_http, prepared)
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) = terminal(opened)
  let assert [first_call] = turn.calls
  let assert Ok(next) =
    llm_wire.prepare(
      settings,
      conversation_fixture.append_results(request(), turn, [
        #(first_call.id, "42"),
      ]),
    )
  let assert Ok(resumed) = llm_wire.stream(owned_http, next)
  let assert Error(failure) = terminal(resumed)
  failure.error |> should.equal(error.DeadlineExceeded(error.WholeCall))
  // `RequestMayHaveReachedProvider` evidence is now `sent: MaybeSent`.
  failure.sent |> should.equal(llm_wire.MaybeSent)
  fake_server.stop(server)
}

pub fn configured_refusal_keeps_usage_test() {
  use owned_http <- http_test_helpers.with_client
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
    llm_wire.prepare(local_config(server.port), request())
  llm_wire.run(owned_http, prepared)
  |> should.equal(
    Ok(llm_wire.Refused("declined", Some(message.Usage(3, 2, 5)))),
  )
  fake_server.stop(server)
}

pub fn caller_supplied_structured_codec_and_correlated_calls_test() {
  use owned_http <- http_test_helpers.with_client
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
  let output_codec = tool_fixtures.one_field("answer", codec.int())
  // Structured output is one more request step in the same family.
  let structured = fn(source) {
    llm_wire.with_output(source, "answer_shape", output_codec)
  }
  let assert Ok(prepared) = llm_wire.prepare(settings, structured(request()))
  let assert Ok(opened) = llm_wire.stream(owned_http, prepared)
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) = terminal(opened)
  llm_wire.request_json(prepared)
  |> string.contains("\"type\":\"json_schema\"")
  |> should.be_true
  let assert [first_call] = turn.calls
  let prepare_next = fn(results) {
    llm_wire.prepare(
      settings,
      structured(conversation_fixture.append_results(request(), turn, results)),
    )
  }
  prepare_next([])
  |> should.equal(
    Error(error.ToolResultMismatch("call_1", error.MissingResult)),
  )
  prepare_next([#("other", "42")])
  |> should.equal(Error(error.ToolResultMismatch("other", error.UnknownCall)))
  prepare_next([#(first_call.id, "42"), #(first_call.id, "42")])
  |> should.equal(
    Error(error.ToolResultMismatch("call_1", error.DuplicateResult)),
  )
  let assert Ok(next) = prepare_next([#(first_call.id, "42")])
  llm_wire.request_json(next)
  |> string.contains("\"type\":\"json_schema\"")
  |> should.be_true
  llm_wire.request_json(next)
  |> string.contains("\"call_id\":\"call_1\"")
  |> should.be_true
  let assert Ok(llm_wire.Answer(output: 42, text: "{\"answer\":42}", ..)) =
    llm_wire.run(owned_http, next)
  fake_server.stop(server)
}
