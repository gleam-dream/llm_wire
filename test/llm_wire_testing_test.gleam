//// The public test provider through the ordinary execution path, and its
//// lowering into the built-in wires. These tests import only public modules;
//// no socket is opened.

import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import http_gun/error as http_error
import http_gun/testing as http_testing
import http_test_helpers
import json/blueprint/codec
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/google
import llm_wire/message
import llm_wire/openai
import llm_wire/testing
import llm_wire/tool
import tool_fixtures

fn request(messages: List(message.Message)) -> llm_wire.Request(String) {
  llm_wire.request("scripted-model", messages)
}

fn lookup_request() -> llm_wire.Request(String) {
  request([llm_wire.user("Find gleam")])
  |> llm_wire.with_tools([tool_fixtures.string_field_tool("lookup", "query")])
}

fn read_all(
  stream: llm_wire.Stream(o),
  seen: List(message.Progress),
) -> #(List(message.Progress), Result(llm_wire.Outcome(o), llm_wire.Failure)) {
  case llm_wire.next(stream) {
    Ok(llm_wire.Progress(progress)) -> read_all(stream, [progress, ..seen])
    Ok(llm_wire.Done(result)) -> #(list.reverse(seen), result)
    Error(_) -> panic as "stream read failed"
  }
}

fn recorded_body(exchange: http_testing.Exchange) -> Result(String, Nil) {
  bit_array.to_string(http_testing.request(exchange).body)
}

pub fn scripted_text_runs_through_the_session_test() {
  let assert Ok(prepared) =
    llm_wire.prepare(testing.config(), request([llm_wire.user("Hi")]))
  http_test_helpers.run_reply(prepared, testing.text("hello"))
  |> should.equal(Ok(llm_wire.Answer("hello", "hello", None)))
  recorded_body(testing.exchange(prepared, testing.text("hello")))
  |> should.equal(Ok(llm_wire.request_json(prepared)))
}

pub fn scripted_usage_is_reported_test() {
  let usage = message.Usage(input_tokens: 3, output_tokens: 2, total_tokens: 5)
  let assert Ok(prepared) =
    llm_wire.prepare(testing.config(), request([llm_wire.user("Hi")]))
  http_test_helpers.run_reply(
    prepared,
    testing.text("hi") |> testing.with_usage(usage),
  )
  |> should.equal(Ok(llm_wire.Answer("hi", "hi", Some(usage))))
}

pub fn scripted_stream_reports_progress_before_the_terminal_test() {
  let assert Ok(prepared) =
    llm_wire.prepare(testing.config(), request([llm_wire.user("Hi")]))
  use client <- http_test_helpers.with_script([
    testing.exchange(prepared, testing.text("streamed")),
  ])
  let assert Ok(stream) = llm_wire.stream(client, prepared)
  let #(progress, outcome) = read_all(stream, [])
  progress |> should.equal([message.TextDelta("0", "streamed")])
  outcome |> should.equal(Ok(llm_wire.Answer("streamed", "streamed", None)))
}

pub fn scripted_tool_round_continues_with_exact_results_test() {
  let assert Ok(prepared) = llm_wire.prepare(testing.config(), lookup_request())
  let assert Ok(llm_wire.NeedsTools(turn:, issues: [], usage: None)) =
    http_test_helpers.run_reply(
      prepared,
      testing.tool_calls("Looking.", [
        testing.ScriptedCall("call_1", "lookup", "{\"query\":\"gleam\"}"),
      ]),
    )
  turn.text |> should.equal("Looking.")
  let assert [call] = turn.calls
  call.id |> should.equal("call_1")
  call.name |> should.equal("lookup")
  call.arguments_json |> should.equal("{\"query\":\"gleam\"}")

  // Coverage is checked before the second scripted reply is consumed.
  let pending = llm_wire.append(lookup_request(), [message.Assistant(turn)])
  llm_wire.prepare(testing.config(), pending)
  |> should.equal(
    Error(error.ToolResultMismatch("call_1", error.MissingResult)),
  )
  let ready =
    llm_wire.append(pending, [llm_wire.tool_result(call, "gleam.run")])
  let assert Ok(next) = llm_wire.prepare(testing.config(), ready)
  http_test_helpers.run_reply(next, testing.text("Found it."))
  |> should.equal(Ok(llm_wire.Answer("Found it.", "Found it.", None)))

  llm_wire.messages(ready)
  |> should.equal([
    message.User("Find gleam"),
    message.Assistant(turn),
    message.ToolResult("call_1", "gleam.run"),
  ])
}

pub fn scripted_structured_output_is_validated_and_decoded_test() {
  let assert Ok(prepared) =
    llm_wire.prepare(
      testing.config(),
      request([llm_wire.user("Answer")])
        |> llm_wire.with_output(
          "answer",
          tool_fixtures.one_field("answer", codec.int()),
        ),
    )
  http_test_helpers.run_reply(prepared, testing.text("{\"answer\":42}"))
  |> should.equal(Ok(llm_wire.Answer(42, "{\"answer\":42}", None)))
}

pub fn scripted_refusal_and_output_limit_are_distinct_outcomes_test() {
  let settings = testing.config()
  let assert Ok(first) =
    llm_wire.prepare(settings, request([llm_wire.user("One")]))
  let assert Ok(second) =
    llm_wire.prepare(settings, request([llm_wire.user("Two")]))
  http_test_helpers.run_reply(first, testing.refusal("no"))
  |> should.equal(Ok(llm_wire.Refused("no", None)))
  http_test_helpers.run_reply(second, testing.output_limited("partial"))
  |> should.equal(Ok(llm_wire.OutputLimited("partial", [], None)))
}

pub fn scripted_status_fails_after_the_request_was_sent_test() {
  let assert Ok(prepared) =
    llm_wire.prepare(testing.config(), request([llm_wire.user("Hi")]))
  let assert Error(failure) =
    http_test_helpers.run_reply(
      prepared,
      testing.Status(429, "{\"error\":\"slow down\"}"),
    )
  failure.error
  |> should.equal(error.Status(429, "{\"error\":\"slow down\"}", None))
  // A finished response with an error status is `Completed` (it was
  // RequestMayHaveReachedProvider with response bytes observed).
  failure.sent |> should.equal(llm_wire.Completed)
  failure.provider |> should.equal(message.Custom("scripted"))
}

pub fn scripted_interruption_is_a_transport_failure_test() {
  let assert Ok(prepared) =
    llm_wire.prepare(testing.config(), request([llm_wire.user("Hi")]))
  let assert Error(llm_wire.Failure(error: error.Http(failure), ..)) =
    http_test_helpers.run_reply(prepared, testing.Interrupted([]))
  http_error.reason(failure)
  |> should.equal(http_error.RequestFailed(http_error.PeerClosed))
}

pub fn exhausted_script_fails_without_a_reply_test() {
  use client <- http_test_helpers.with_script([])
  let assert Ok(prepared) =
    llm_wire.prepare(testing.config(), request([llm_wire.user("Hi")]))
  let assert Error(failure) = llm_wire.run(client, prepared)
  let assert error.Http(http_failure) = failure.error
  http_error.reason(http_failure) |> should.equal(http_error.PlaybackExhausted)
  // Was `initial_retry_evidence()`: nothing sent, no progress.
  failure.sent |> should.equal(llm_wire.NotSent)
  failure.partial_output |> should.be_false
  failure.usage |> should.equal(None)
}

pub fn raw_events_drive_a_built_in_provider_without_a_socket_test() {
  let body =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"item\",\"delta\":\"ok\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}\n\n"
  let settings = openai.new("sk-scripted") |> openai.config
  let assert Ok(prepared) =
    llm_wire.prepare(settings, request([llm_wire.user("Hi")]))
  // Split inside an event: the SSE framer must reassemble it.
  http_test_helpers.run_reply(
    prepared,
    testing.Events([string.slice(body, 0, 40), string.drop_start(body, 40)]),
  )
  |> should.equal(Ok(llm_wire.Answer("ok", "ok", None)))
  let exchange = testing.exchange(prepared, testing.Events([]))
  http_testing.request(exchange).path |> should.equal("/v1/responses")
  recorded_body(exchange) |> should.equal(Ok(llm_wire.request_json(prepared)))
}

// --- events_for: built-in wire lowering -------------------------------------

fn wires() -> List(#(message.Provider, llm_wire.Config)) {
  [
    #(message.OpenAI, openai.new("k") |> openai.config),
    #(message.Anthropic, anthropic.new("k") |> anthropic.config),
    #(message.Google, google.new("k") |> google.config),
  ]
}

fn run_lowered(
  config: llm_wire.Config,
  provider: message.Provider,
  source: llm_wire.Request(String),
  reply: testing.Reply,
) -> Result(llm_wire.Outcome(String), llm_wire.Failure) {
  let assert Ok(prepared) = llm_wire.prepare(config, source)
  http_test_helpers.run_reply(prepared, testing.events_for(provider, reply))
}

pub fn events_for_text_with_usage_in_every_wire_test() {
  use #(provider, config) <- list.each(wires())
  let usage = message.Usage(input_tokens: 4, output_tokens: 6, total_tokens: 10)
  let outcome =
    run_lowered(
      config,
      provider,
      request([llm_wire.user("Hi")]),
      testing.text("Bonjour") |> testing.with_usage(usage),
    )
  outcome
  |> should.equal(Ok(llm_wire.Answer("Bonjour", "Bonjour", Some(usage))))
}

pub fn events_for_text_streams_progress_in_every_wire_test() {
  use #(provider, config) <- list.each(wires())
  let assert Ok(prepared) =
    llm_wire.prepare(config, request([llm_wire.user("Hi")]))
  use client <- http_test_helpers.with_script([
    testing.exchange(
      prepared,
      testing.events_for(provider, testing.text("streamed")),
    ),
  ])
  let assert Ok(stream) = llm_wire.stream(client, prepared)
  let #(progress, outcome) = read_all(stream, [])
  list.filter_map(progress, fn(item) {
    case item {
      message.TextDelta(_, text) -> Ok(text)
      _ -> Error(Nil)
    }
  })
  |> string.concat
  |> should.equal("streamed")
  let assert Ok(llm_wire.Answer(text: "streamed", ..)) = outcome
}

pub fn events_for_multiple_tool_calls_in_every_wire_test() {
  use #(provider, config) <- list.each(wires())
  let source =
    request([llm_wire.user("Weather?")])
    |> llm_wire.with_tools([
      tool_fixtures.string_field_tool("lookup", "query"),
      tool_fixtures.int_field_tool("count", "n"),
    ])
  let assert Ok(prepared) = llm_wire.prepare(config, source)
  let reply =
    testing.tool_calls("Checking", [
      testing.ScriptedCall("call_a", "lookup", "{\"query\":\"paris\"}"),
      testing.ScriptedCall("call_b", "count", "{\"n\":3}"),
    ])
  let assert Ok(llm_wire.NeedsTools(turn:, issues: [], ..)) =
    http_test_helpers.run_reply(prepared, testing.events_for(provider, reply))
  turn.provider |> should.equal(Some(provider))
  turn.text |> should.equal("Checking")
  let assert [first, second] = turn.calls
  #(first.id, first.name) |> should.equal(#("call_a", "lookup"))
  #(second.id, second.name) |> should.equal(#("call_b", "count"))
  tool.decode_arguments(first, tool_fixtures.one_field("query", codec.string()))
  |> should.equal(Ok("paris"))
  tool.decode_arguments(second, tool_fixtures.one_field("n", codec.int()))
  |> should.equal(Ok(3))
  // The turn and both results replay into the next request.
  let next =
    llm_wire.append(source, [
      message.Assistant(turn),
      llm_wire.tool_result(first, "sunny"),
      llm_wire.tool_result(second, "3"),
    ])
  let assert Ok(_) = llm_wire.prepare(config, next)
}

pub fn events_for_refusal_in_every_wire_test() {
  use #(provider, config) <- list.each(wires())
  let assert Ok(llm_wire.Refused(reason:, usage: _)) =
    run_lowered(
      config,
      provider,
      request([llm_wire.user("Hi")]),
      testing.refusal("unsafe"),
    )
  // Gemini reports a blocked prompt with its own prefix.
  reason
  |> should.equal(case provider {
    message.Google -> "Prompt blocked by safety policy: unsafe"
    _ -> "unsafe"
  })
}

pub fn events_for_output_limited_in_every_wire_test() {
  use #(provider, config) <- list.each(wires())
  let assert Ok(llm_wire.OutputLimited(partial_text:, partial_calls:, ..)) =
    run_lowered(
      config,
      provider,
      request([llm_wire.user("Hi")]),
      testing.output_limited("Once upon"),
    )
  partial_text |> should.equal("Once upon")
  partial_calls |> should.equal([])
}

pub fn events_for_interrupted_is_a_transport_failure_in_every_wire_test() {
  use #(provider, config) <- list.each(wires())
  // A scripted text event with no end, then the connection drops.
  let assert testing.Events([text_event, ..]) = testing.text("partial")
  let lowered = testing.events_for(provider, testing.Interrupted([text_event]))
  let assert testing.Interrupted([_, ..]) = lowered
  let assert Ok(prepared) =
    llm_wire.prepare(config, request([llm_wire.user("Hi")]))
  let assert Error(failure) = http_test_helpers.run_reply(prepared, lowered)
  let assert error.Http(http_failure) = failure.error
  http_error.reason(http_failure)
  |> should.equal(http_error.RequestFailed(http_error.PeerClosed))
  failure.sent |> should.equal(llm_wire.MaybeSent)
  failure.provider |> should.equal(provider)
}

pub fn events_for_keeps_status_and_custom_replies_test() {
  list.each(wires(), fn(wire) {
    testing.events_for(wire.0, testing.Status(503, "busy"))
    |> should.equal(testing.Status(503, "busy"))
  })
  let replies = [
    testing.text("a"),
    testing.refusal("r"),
    testing.Interrupted(["x"]),
    testing.Status(429, "slow"),
  ]
  list.each(replies, fn(reply) {
    testing.events_for(message.Custom("acme"), reply) |> should.equal(reply)
  })
}

pub fn events_for_status_still_fails_with_the_status_test() {
  use #(provider, config) <- list.each(wires())
  let assert Error(failure) =
    run_lowered(
      config,
      provider,
      request([llm_wire.user("Hi")]),
      testing.Status(503, "busy"),
    )
  failure.error |> should.equal(error.Status(503, "busy", None))
  failure.provider |> should.equal(provider)
}

/// OpenAI's lowered text is one delta event whose line far exceeds 16 KiB; the
/// default line limit is 1 MiB.
pub fn events_for_long_openai_text_succeeds_test() {
  let long = string.repeat("lorem ipsum ", 2000)
  { string.byte_size(long) > 16_384 } |> should.be_true
  let assert Ok(llm_wire.Answer(text:, ..)) =
    run_lowered(
      openai.new("k") |> openai.config,
      message.OpenAI,
      request([llm_wire.user("Hi")]),
      testing.text(long),
    )
  text |> should.equal(long)
}
