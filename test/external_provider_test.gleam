import conversation_fixture
import external_provider
import fake_server
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import http_test_helpers
import json/blueprint/codec
import llm_wire
import llm_wire/error
import llm_wire/limit
import llm_wire/message
import llm_wire/provider
import tool_fixtures

fn settings(port: Int) -> llm_wire.Config {
  provider.config(external_provider.adapter(
    "http://127.0.0.1:" <> int.to_string(port),
  ))
}

/// Was a failing reducer constructor, which no longer exists: `new_reducer`
/// cannot fail. The closest pre-transport failure is a connection that is
/// refused before the request leaves; it must keep `NotSent` evidence for a
/// custom adapter, plain and structured.
pub fn pretransport_failure_preserves_not_sent_evidence_test() {
  use owned_http <- http_test_helpers.with_client
  let settings = settings(1)
  let assert Ok(prepared) = llm_wire.prepare(settings, request(False))
  let assert Error(failure) = llm_wire.run(owned_http, prepared)
  let assert error.Http(_) = failure.error
  failure.sent |> should.equal(llm_wire.NotSent)
  failure.partial_output |> should.be_false
  failure.provider |> should.equal(message.Custom("scripted-fourth"))
  let assert Ok(structured) =
    llm_wire.prepare(
      settings,
      request(False)
        |> llm_wire.with_output(
          "answer",
          tool_fixtures.one_field("answer", codec.int()),
        ),
    )
  let assert Error(failure) = llm_wire.run(owned_http, structured)
  let assert error.Http(_) = failure.error
  failure.sent |> should.equal(llm_wire.NotSent)
}

fn request(with_tool: Bool) -> llm_wire.Request(String) {
  let base = llm_wire.request("fourth-model", [llm_wire.user("hello")])
  case with_tool {
    True ->
      llm_wire.with_tools(base, [tool_fixtures.int_field_tool("calc", "x")])
    False -> base
  }
}

fn terminal(
  stream: llm_wire.Stream(o),
) -> Result(llm_wire.Outcome(o), llm_wire.Failure) {
  case llm_wire.next(stream) {
    Ok(llm_wire.Progress(_)) -> terminal(stream)
    Ok(llm_wire.Done(result)) -> result
    Error(_) -> panic as "stream read failed"
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
    llm_wire.prepare(settings(server.port), request(False))
  llm_wire.run(owned_http, prepared)
  |> should.equal(Ok(llm_wire.Answer("Hello fourth!", "Hello fourth!", None)))
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
    llm_wire.prepare(settings(server.port), request(True))
  let assert Ok(llm_wire.NeedsTools(turn:, issues: [], usage: None)) =
    llm_wire.run(owned_http, prepared)
  turn.text |> should.equal("Before tool")
  turn.provider |> should.equal(Some(message.Custom("scripted-fourth")))
  let assert [call] = turn.calls
  let prepare_next = fn(results) {
    llm_wire.prepare(
      settings(server.port),
      conversation_fixture.append_results(request(True), turn, results),
    )
  }
  let assert Error(error.ToolResultMismatch("call-1", error.MissingResult)) =
    prepare_next([])
  let assert Error(error.ToolResultMismatch("call-1", error.DuplicateResult)) =
    prepare_next([#(call.id, "14"), #(call.id, "14")])
  let assert Ok(next) = prepare_next([#(call.id, "14")])
  let body = llm_wire.request_json(next)
  string.contains(body, "\"replay_text\":\"Before tool\"") |> should.be_true
  string.contains(body, "\"text\":\"Before tool\"") |> should.be_true
  string.contains(body, "\"call_id\":\"call-1\"") |> should.be_true
  llm_wire.run(owned_http, next)
  |> should.equal(Ok(llm_wire.Answer("Answer 14", "Answer 14", None)))
  fake_server.stop(server)
}

fn run_bounded_event(
  event_stream: String,
  limits: List(#(limit.Limit, Int)),
  with_tool: Bool,
) -> Result(llm_wire.Outcome(String), llm_wire.Failure) {
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
  let configured =
    list.fold(limits, settings(server.port), fn(config, bound) {
      llm_wire.with_limit(config, bound.0, bound.1)
    })
  let assert Ok(prepared) = llm_wire.prepare(configured, request(with_tool))
  let assert Ok(stream) = llm_wire.stream(owned_http, prepared)
  let outcome = terminal(stream)
  fake_server.stop(server)
  outcome
}

fn limit_failure(
  outcome: Result(llm_wire.Outcome(String), llm_wire.Failure),
) -> #(limit.Limit, llm_wire.Failure) {
  let assert Error(failure) = outcome
  let assert error.LimitExceeded(exceeded, _, _) = failure.error
  #(exceeded, failure)
}

pub fn external_provider_cannot_bypass_progress_or_terminal_limits_test() {
  let limits = [
    #(limit.TextBytesPerBlock, 5),
    #(limit.TotalTextBytes, 7),
    #(limit.ArgumentBytesPerCall, 8),
    #(limit.ExtensionBytes, 30),
  ]
  let #(exceeded, failure) =
    run_bounded_event(
      "event: text\ndata: first\n\nevent: text\ndata: next\n\n",
      limits,
      False,
    )
    |> limit_failure
  exceeded |> should.equal(limit.TextBytesPerBlock)
  // Was response bytes and semantic progress observed.
  failure.partial_output |> should.be_true
  failure.sent |> should.equal(llm_wire.MaybeSent)

  run_bounded_event(
    "event: oversized_done\ndata: over-limit\n\n",
    limits,
    False,
  )
  |> limit_failure
  |> fn(pair) { pair.0 }
  |> should.equal(limit.TextBytesPerBlock)

  let #(exceeded, failure) =
    run_bounded_event(
      "event: batch_over_limit\ndata: larger\n\n",
      limits,
      False,
    )
    |> limit_failure
  exceeded |> should.equal(limit.TextBytesPerBlock)
  failure.partial_output |> should.be_true

  run_bounded_event(
    "event: long_id\ndata: retained-block-identifier\n\n",
    [#(limit.QueueBytes, 45)],
    False,
  )
  |> limit_failure
  |> fn(pair) { pair.0 }
  |> should.equal(limit.QueueBytes)

  run_bounded_event(
    "event: metadata_tool\ndata: provider-state-that-exceeds-the-budget\n\n",
    [#(limit.ProviderMetadataBytes, 40)],
    True,
  )
  |> limit_failure
  |> fn(pair) { pair.0 }
  |> should.equal(limit.ProviderMetadataBytes)

  let assert Error(catalog) =
    run_bounded_event(
      "event: tool\ndata: call-1|ghost|{}\n\nevent: done\ndata: ok\n\n",
      limits,
      True,
    )
  let assert error.Protocol(_) = catalog.error
  // Was response bytes observed: a finished response with invalid content
  // is `Completed`.
  catalog.sent |> should.equal(llm_wire.Completed)

  run_bounded_event(
    "event: tool\ndata: call-1|calc|123456789\n\nevent: limited\ndata: ok\n\n",
    limits,
    True,
  )
  |> limit_failure
  |> fn(pair) { pair.0 }
  |> should.equal(limit.ArgumentBytesPerCall)

  run_bounded_event(
    "event: refusal\ndata: Refusal longer than seven\n\n",
    limits,
    False,
  )
  |> limit_failure
  |> fn(pair) { pair.0 }
  |> should.equal(limit.TotalTextBytes)

  run_bounded_event(
    "event: extension\ndata: this-is-a-long-extension-name\n\n",
    limits,
    False,
  )
  |> limit_failure
  |> fn(pair) { pair.0 }
  |> should.equal(limit.ExtensionBytes)
}

/// The reducer's own failure terminal surfaces as a provider error after the
/// response completed.
pub fn external_provider_failure_terminal_is_a_provider_error_test() {
  let assert Error(failure) =
    run_bounded_event("event: failure\ndata: broken\n\n", [], False)
  failure.error |> should.equal(error.Provider(Some("fixture"), "broken"))
  failure.provider |> should.equal(message.Custom("scripted-fourth"))
  llm_wire.advise(failure).prospect |> should.equal(llm_wire.Unknown)
}
