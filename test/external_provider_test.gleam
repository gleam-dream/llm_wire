import conversation_fixture
import external_provider
import fake_server
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/option.{None}
import gleam/string
import gleeunit/should
import http_test_helpers
import json/blueprint/codec
import llm_wire/config
import llm_wire/session
import llm_wire/types
import tool_fixtures

fn settings(port: Int) -> config.Config {
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(port))
  config.from_provider(external_provider.adapter(endpoint))
}

pub fn buffered_open_failure_preserves_pretransport_retry_evidence_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(endpoint) = types.endpoint("http://127.0.0.1:1")
  let settings =
    config.from_provider(external_provider.failing_adapter(endpoint))
  let assert Ok(prepared) = session.prepare(settings, request(False))
  case session.run(owned_http, prepared) {
    Error(session.RunFailure(types.ConfigurationError(_), retry)) -> {
      retry.classification |> should.equal(types.NoRequestSent)
      retry.response_bytes_observed |> should.be_false
    }
    _ -> should.fail()
  }
  let assert Ok(structured) =
    session.prepare_structured(
      settings,
      request(False),
      "answer",
      codec.field("answer", codec.int()),
    )
  case session.run_structured(owned_http, structured) {
    Error(session.RunFailure(types.ConfigurationError(_), retry)) ->
      retry.classification |> should.equal(types.NoRequestSent)
    _ -> should.fail()
  }
}

fn request(with_tool: Bool) -> types.Request {
  let assert Ok(model) = types.model_id("fourth-model")
  let base = types.new_request(model, [types.UserMessage("hello")])
  case with_tool {
    True -> types.with_tools(base, [tool_fixtures.int_field_tool("calc", "x")])
    False -> base
  }
}

fn terminal(stream: session.Stream) -> session.Terminal {
  case session.next(stream) {
    Ok(session.NextProgress(_)) -> terminal(stream)
    Ok(session.StreamTerminal(value)) -> value
    Error(session.StreamReadError(types.ReadTimeout)) -> terminal(stream)
    Error(_) -> {
      should.fail()
      terminal(stream)
    }
  }
}

pub fn external_provider_text_over_real_http_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_) = fake_server.read_request_headers(socket, 2000)
    let _ =
      fake_server.send_sse_stream(
        socket,
        [
          #(
            0,
            bit_array.from_string(
              "event: text\ndata: Hello \n\nevent: text\ndata: fourth!\n\nevent: done\ndata: ok\n\n",
            ),
          ),
        ],
        True,
      )
    Nil
  })
  let assert Ok(prepared) =
    session.prepare(settings(server.port), request(False))
  let assert Ok(session.RunText("Hello fourth!", None)) =
    session.run(owned_http, prepared)
  fake_server.stop(server)
}

pub fn external_provider_data_preserves_text_and_exact_tool_results_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(first) = fake_server.accept_connection(server, 2000)
    let assert Ok(_) = fake_server.read_request_headers(first, 2000)
    let _ =
      fake_server.send_sse_stream(
        first,
        [
          #(
            0,
            bit_array.from_string(
              "event: text\ndata: Before tool\n\nevent: tool\ndata: call-1|calc|{\"x\":7}\n\nevent: done\ndata: ok\n\n",
            ),
          ),
        ],
        True,
      )
    let assert Ok(second) = fake_server.accept_connection(server, 2000)
    let assert Ok(_) = fake_server.read_request_headers(second, 2000)
    let _ =
      fake_server.send_sse_stream(
        second,
        [
          #(
            0,
            bit_array.from_string(
              "event: text\ndata: Answer 14\n\nevent: done\ndata: ok\n\n",
            ),
          ),
        ],
        True,
      )
    Nil
  })
  let assert Ok(prepared) =
    session.prepare(settings(server.port), request(True))
  let assert Ok(session.RunToolCalls(turn, None)) =
    session.run(owned_http, prepared)
  turn.text |> should.equal("Before tool")
  let assert [call] = turn.calls
  let prepare_next = fn(results) {
    session.prepare(
      settings(server.port),
      conversation_fixture.append_results(request(True), turn, results),
    )
  }
  prepare_next([]) |> should.be_error
  prepare_next([
    types.ToolResult(call.id, "14"),
    types.ToolResult(call.id, "14"),
  ])
  |> should.be_error
  let assert Ok(next) = prepare_next([types.ToolResult(call.id, "14")])
  let body = session.prepared_request_json(next)
  string.contains(body, "\"replay_text\":\"Before tool\"") |> should.be_true
  string.contains(body, "\"text\":\"Before tool\"") |> should.be_true
  string.contains(body, "\"call_id\":\"call-1\"") |> should.be_true
  let assert Ok(session.RunText("Answer 14", None)) =
    session.run(owned_http, next)
  fake_server.stop(server)
}

fn run_bounded_event(
  event_stream: String,
  limits: types.Limits,
  with_tool: Bool,
) -> session.Terminal {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_) = fake_server.read_request_headers(socket, 2000)
    let _ =
      fake_server.send_sse_stream(
        socket,
        [#(0, bit_array.from_string(event_stream))],
        True,
      )
    Nil
  })
  let configured = settings(server.port) |> config.with_limits(limits)
  let assert Ok(prepared) = session.prepare(configured, request(with_tool))
  let assert Ok(stream) = session.stream(owned_http, prepared)
  let outcome = terminal(stream)
  fake_server.stop(server)
  outcome
}

pub fn external_provider_cannot_bypass_progress_or_terminal_limits_test() {
  let limits =
    types.Limits(
      ..types.default_limits(),
      text_bytes_per_block_limit: 5,
      total_text_bytes_limit: 7,
      argument_bytes_per_call_limit: 8,
      extension_bytes_limit: 30,
    )
  let text_outcome =
    run_bounded_event(
      "event: text\ndata: first\n\nevent: text\ndata: next\n\n",
      limits,
      False,
    )
  case text_outcome {
    session.Failed(
      types.ResourceLimitExceeded("text_bytes_per_block_limit", _, _),
      retry,
    ) -> {
      retry.response_bytes_observed |> should.be_true
      retry.semantic_progress_observed |> should.be_true
    }
    _ -> should.fail()
  }
  let same_event_outcome =
    run_bounded_event(
      "event: oversized_done\ndata: over-limit\n\n",
      limits,
      False,
    )
  case same_event_outcome {
    session.Failed(
      types.ResourceLimitExceeded("text_bytes_per_block_limit", _, _),
      _,
    ) -> should.be_true(True)
    _ -> should.fail()
  }
  let batch_outcome =
    run_bounded_event(
      "event: batch_over_limit\ndata: larger\n\n",
      limits,
      False,
    )
  case batch_outcome {
    session.Failed(
      types.ResourceLimitExceeded("text_bytes_per_block_limit", _, _),
      retry,
    ) -> retry.semantic_progress_observed |> should.be_true
    _ -> should.fail()
  }
  let queue_limits =
    types.Limits(..types.default_limits(), queue_bytes_limit: 45)
  let queued_id_outcome =
    run_bounded_event(
      "event: long_id\ndata: retained-block-identifier\n\n",
      queue_limits,
      False,
    )
  case queued_id_outcome {
    session.Failed(types.ResourceLimitExceeded("queue_bytes_limit", _, _), _) ->
      should.be_true(True)
    _ -> should.fail()
  }
  let metadata_limits =
    types.Limits(..types.default_limits(), provider_metadata_bytes_limit: 40)
  let metadata_outcome =
    run_bounded_event(
      "event: metadata_tool\ndata: provider-state-that-exceeds-the-budget\n\n",
      metadata_limits,
      True,
    )
  case metadata_outcome {
    session.Failed(
      types.ResourceLimitExceeded("provider_metadata_bytes_limit", _, _),
      _,
    ) -> should.be_true(True)
    _ -> should.fail()
  }
  let catalog_outcome =
    run_bounded_event(
      "event: tool\ndata: call-1|ghost|{}\n\nevent: done\ndata: ok\n\n",
      limits,
      True,
    )
  case catalog_outcome {
    session.Failed(types.ProtocolError(_), retry) ->
      retry.response_bytes_observed |> should.be_true
    _ -> should.fail()
  }
  let partial_outcome =
    run_bounded_event(
      "event: tool\ndata: call-1|calc|123456789\n\nevent: limited\ndata: ok\n\n",
      limits,
      True,
    )
  case partial_outcome {
    session.Failed(
      types.ResourceLimitExceeded("argument_bytes_per_call_limit", _, _),
      _,
    ) -> should.be_true(True)
    _ -> should.fail()
  }
  let refusal_outcome =
    run_bounded_event(
      "event: refusal\ndata: Refusal longer than seven\n\n",
      limits,
      False,
    )
  case refusal_outcome {
    session.Failed(
      types.ResourceLimitExceeded("total_text_bytes_limit", _, _),
      _,
    ) -> should.be_true(True)
    _ -> should.fail()
  }
  let extension_outcome =
    run_bounded_event(
      "event: extension\ndata: this-is-a-long-extension-name\n\n",
      limits,
      False,
    )
  case extension_outcome {
    session.Failed(
      types.ResourceLimitExceeded("extension_bytes_limit", _, _),
      _,
    ) -> should.be_true(True)
    _ -> should.fail()
  }
}
