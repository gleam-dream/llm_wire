//// The public test provider through the ordinary execution path, and its
//// lowering into the built-in wires. These tests import only public modules;
//// no socket is opened.

import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
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
        testing.tool_call("call_1", "lookup", "{\"query\":\"gleam\"}"),
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
      testing.http_status(
        message.Custom("scripted"),
        429,
        "{\"error\":\"slow down\"}",
      ),
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
    http_test_helpers.run_reply(
      prepared,
      testing.interrupted(testing.events([])),
    )
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
    testing.events([string.slice(body, 0, 40), string.drop_start(body, 40)]),
  )
  |> should.equal(Ok(llm_wire.Answer("ok", "ok", None)))
  let exchange = testing.exchange(prepared, testing.events([]))
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
      testing.tool_call("call_a", "lookup", "{\"query\":\"paris\"}"),
      testing.tool_call("call_b", "count", "{\"n\":3}"),
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

pub fn events_for_refusal_on_openai_and_the_scripted_wire_test() {
  let wires = [
    #(message.OpenAI, openai.new("k") |> openai.config),
    #(message.Custom("scripted"), testing.config()),
  ]
  use #(provider, config) <- list.each(wires)
  let assert Ok(llm_wire.Refused(reason: "unsafe", usage: _)) =
    run_lowered(
      config,
      provider,
      request([llm_wire.user("Hi")]),
      testing.refusal("unsafe"),
    )
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
  let lowered =
    testing.events_for(provider, testing.interrupted(testing.text("partial")))
  testing.is_interrupted(lowered) |> should.be_true
  let assert [_, ..] = testing.chunks(lowered)
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
    testing.events_for(
      wire.0,
      testing.http_status(message.Custom("scripted"), 503, "busy"),
    )
    |> should.equal(testing.http_status(message.Custom("scripted"), 503, "busy"))
  })
  let replies = [
    testing.text("a"),
    testing.refusal("r"),
    testing.interrupted(testing.events(["x"])),
    testing.http_status(message.Custom("scripted"), 429, "slow"),
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
      testing.http_status(message.Custom("scripted"), 503, "busy"),
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

// --- failure replies ----------------------------------------------------------

fn hi() -> llm_wire.Request(String) {
  request([llm_wire.user("Hi")])
}

fn run_in(
  config: llm_wire.Config,
  reply: testing.Reply,
) -> Result(llm_wire.Outcome(String), llm_wire.Failure) {
  let assert Ok(prepared) = llm_wire.prepare(config, hi())
  http_test_helpers.run_reply(prepared, reply)
}

pub fn interrupted_is_a_transport_failure_after_the_content_in_every_wire_test() {
  use #(provider, config) <- list.each(wires())
  let reply =
    testing.interrupted(testing.text("partial"))
    |> testing.events_for(provider, _)
  testing.is_interrupted(reply) |> should.be_true
  let assert [_, ..] = testing.chunks(reply)
  let assert Error(failure) = run_in(config, reply)
  let assert error.Http(http_failure) = failure.error
  http_error.reason(http_failure)
  |> should.equal(http_error.RequestFailed(http_error.PeerClosed))
  failure.sent |> should.equal(llm_wire.MaybeSent)
  failure.provider |> should.equal(provider)
  // The text had streamed before the connection dropped.
  failure.partial_output |> should.be_true
}

pub fn interrupted_drops_the_scripted_end_and_keeps_the_rest_test() {
  let whole = testing.chunks(testing.text("partial"))
  let cut = testing.chunks(testing.interrupted(testing.text("partial")))
  list.length(cut) |> should.equal(list.length(whole) - 1)
  list.take(whole, list.length(cut)) |> should.equal(cut)
}

pub fn interrupted_leaves_status_and_interrupted_replies_alone_test() {
  testing.interrupted(testing.http_status(
    message.Custom("scripted"),
    503,
    "busy",
  ))
  |> should.equal(testing.http_status(message.Custom("scripted"), 503, "busy"))
  let cut = testing.interrupted(testing.events(["x"]))
  testing.interrupted(cut) |> should.equal(cut)
}

pub fn interrupted_on_the_scripted_wire_fails_the_call_test() {
  let assert Error(failure) =
    run_in(testing.config(), testing.interrupted(testing.text("partial")))
  let assert error.Http(_) = failure.error
  failure.partial_output |> should.be_true
}

pub fn rate_limited_is_a_429_status_in_every_wire_test() {
  use #(provider, config) <- list.each(wires())
  let assert Error(failure) = run_in(config, testing.rate_limited(provider))
  let assert error.Status(429, body, None) = failure.error
  string.contains(body, "Rate limit reached") |> should.be_true
  failure.provider |> should.equal(provider)
  failure.sent |> should.equal(llm_wire.Completed)
  llm_wire.advise(failure)
  |> should.equal(llm_wire.RetryAdvice(llm_wire.MayHelp, llm_wire.Backoff))
}

pub fn retry_after_makes_the_advice_a_provider_delay_in_every_wire_test() {
  use #(provider, config) <- list.each(wires())
  let assert Ok(prepared) = llm_wire.prepare(config, hi())
  use client <- http_test_helpers.with_script([
    testing.exchange(prepared, testing.rate_limited(provider))
    |> testing.with_retry_after(duration.seconds(7)),
  ])
  let assert Error(failure) = llm_wire.run(client, prepared)
  let assert error.Status(429, _, Some(delay)) = failure.error
  delay |> should.equal(duration.seconds(7))
  llm_wire.advise(failure)
  |> should.equal(llm_wire.RetryAdvice(
    llm_wire.MayHelp,
    llm_wire.ProviderDelay(duration.seconds(7)),
  ))
}

fn retry_after_header(exchange: http_testing.Exchange) -> Result(String, Nil) {
  let assert http_testing.Respond(http, _) = http_testing.reply(exchange)
  list.key_find(http.headers, "retry-after")
}

pub fn retry_after_rounds_a_fraction_up_to_whole_seconds_test() {
  let assert Ok(prepared) = llm_wire.prepare(testing.config(), hi())
  let limited = testing.exchange(prepared, testing.rate_limited(message.OpenAI))
  retry_after_header(limited) |> should.equal(Error(Nil))
  retry_after_header(testing.with_retry_after(
    limited,
    duration.milliseconds(1500),
  ))
  |> should.equal(Ok("2"))
  retry_after_header(testing.with_retry_after(limited, duration.seconds(0)))
  |> should.equal(Ok("0"))
}

pub fn with_retry_after_keeps_the_request_and_the_body_test() {
  let assert Ok(prepared) = llm_wire.prepare(testing.config(), hi())
  let plain =
    testing.exchange(
      prepared,
      testing.http_status(message.Custom("scripted"), 429, "slow"),
    )
  let delayed = testing.with_retry_after(plain, duration.seconds(3))
  http_testing.request(delayed) |> should.equal(http_testing.request(plain))
  let assert http_testing.Respond(before, _) = http_testing.reply(plain)
  let assert http_testing.Respond(after, _) = http_testing.reply(delayed)
  after.status |> should.equal(before.status)
  after.body |> should.equal(before.body)
}

pub fn with_retry_after_leaves_an_exchange_without_a_response_alone_test() {
  let assert Ok(prepared) = llm_wire.prepare(testing.config(), hi())
  let request =
    http_testing.request(testing.exchange(prepared, testing.text("")))
  let rejected =
    http_testing.exchange(
      request,
      http_testing.Reject(http_error.new(
        http_error.RequestFailed(http_error.ConnectionReset),
        http_error.NotSent,
      )),
    )
  testing.with_retry_after(rejected, duration.seconds(1))
  |> should.equal(rejected)
}

pub fn overloaded_uses_each_providers_status_test() {
  let status = fn(provider) { testing.status(testing.overloaded(provider)) }
  status(message.OpenAI) |> should.equal(503)
  status(message.Google) |> should.equal(503)
  status(message.Anthropic) |> should.equal(529)
  status(message.Custom("acme")) |> should.equal(503)
}

pub fn overloaded_fails_with_a_status_that_may_help_in_every_wire_test() {
  use #(provider, config) <- list.each(wires())
  let assert Error(failure) = run_in(config, testing.overloaded(provider))
  let assert error.Status(code, _, None) = failure.error
  { code == 503 || code == 529 } |> should.be_true
  llm_wire.advise(failure).prospect |> should.equal(llm_wire.MayHelp)
}

pub fn error_bodies_follow_each_providers_shape_test() {
  let body = fn(reply) {
    let assert [body] = testing.chunks(reply)
    body
  }
  body(testing.rate_limited(message.OpenAI))
  |> string.contains("\"type\":\"requests\"")
  |> should.be_true
  body(testing.rate_limited(message.Anthropic))
  |> string.contains("\"type\":\"rate_limit_error\"")
  |> should.be_true
  body(testing.overloaded(message.Anthropic))
  |> string.contains("\"type\":\"overloaded_error\"")
  |> should.be_true
  body(testing.rate_limited(message.Google))
  |> string.contains("\"status\":\"RESOURCE_EXHAUSTED\"")
  |> should.be_true
  body(testing.http_status(message.Google, 503, "down"))
  |> string.contains("\"status\":\"UNAVAILABLE\"")
  |> should.be_true
  body(testing.http_status(message.Custom("acme"), 500, "boom"))
  |> should.equal("boom")
}

pub fn http_status_fails_with_that_status_in_every_wire_test() {
  use #(provider, config) <- list.each(wires())
  let assert Error(failure) =
    run_in(config, testing.http_status(provider, 400, "bad request"))
  let assert error.Status(400, body, None) = failure.error
  string.contains(body, "bad request") |> should.be_true
  llm_wire.advise(failure).prospect
  |> should.equal(llm_wire.WillNotHelpUnchanged)
}

pub fn events_for_leaves_a_failure_reply_as_built_test() {
  use #(provider, _) <- list.each(wires())
  let reply = testing.rate_limited(provider)
  testing.events_for(provider, reply) |> should.equal(reply)
}

pub fn invalid_output_fails_a_structured_call_with_the_raw_text_test() {
  use #(provider, config) <- list.each(wires())
  let source =
    hi()
    |> llm_wire.with_output(
      "answer",
      tool_fixtures.one_field("answer", codec.int()),
    )
  let assert Ok(prepared) = llm_wire.prepare(config, source)
  let assert Error(failure) =
    http_test_helpers.run_reply(
      prepared,
      testing.events_for(provider, testing.invalid_output()),
    )
  let assert error.InvalidOutput(raw_output:, ..) = failure.error
  raw_output |> should.equal("this is not valid structured output")
  failure.sent |> should.equal(llm_wire.Completed)
}

pub fn invalid_output_is_an_ordinary_answer_to_a_plain_call_test() {
  let assert Ok(llm_wire.Answer(..)) =
    run_in(testing.config(), testing.invalid_output())
}

// --- fake servers ---------------------------------------------------------------

pub fn http_response_sends_the_lowered_events_as_one_body_test() {
  let http = testing.http_response(message.OpenAI, testing.text("hi"))
  http.status |> should.equal(200)
  http.headers
  |> list.key_find("content-type")
  |> should.equal(Ok("text/event-stream"))
  let chunks =
    testing.chunks(testing.events_for(message.OpenAI, testing.text("hi")))
  http.body |> should.equal(string.concat(chunks))
}

pub fn http_response_keeps_a_failure_status_and_picks_its_content_type_test() {
  let limited =
    testing.http_response(
      message.Anthropic,
      testing.rate_limited(message.Anthropic),
    )
  limited.status |> should.equal(429)
  limited.headers
  |> list.key_find("content-type")
  |> should.equal(Ok("application/json"))
  let proxy =
    testing.http_response(
      message.OpenAI,
      testing.http_status(message.Custom("scripted"), 502, "bad gateway"),
    )
  proxy.status |> should.equal(502)
  proxy.body |> should.equal("bad gateway")
  proxy.headers
  |> list.key_find("content-type")
  |> should.equal(Ok("text/plain"))
}

pub fn http_response_of_an_interrupted_reply_has_the_chunks_so_far_test() {
  let whole = testing.http_response(message.OpenAI, testing.text("partial"))
  let cut =
    testing.http_response(
      message.OpenAI,
      testing.interrupted(testing.text("partial")),
    )
  cut.status |> should.equal(200)
  { string.length(cut.body) < string.length(whole.body) } |> should.be_true
}

// --- failure values ---------------------------------------------------------------

pub fn failure_builds_what_a_failed_call_returns_test() {
  let built = testing.failure(message.OpenAI, error.Status(429, "slow", None))
  built.provider |> should.equal(message.OpenAI)
  built.sent |> should.equal(llm_wire.Completed)
  built.partial_output |> should.be_false
  built.usage |> should.equal(None)
  // A scripted call returns the same evidence.
  let assert Error(returned) =
    run_in(
      openai.new("k") |> openai.config,
      testing.http_status(message.OpenAI, 429, "slow"),
    )
  returned.sent |> should.equal(built.sent)
  returned.provider |> should.equal(built.provider)
  returned.usage |> should.equal(built.usage)
  returned.partial_output |> should.equal(built.partial_output)
}

pub fn failure_follows_the_error_for_what_was_sent_test() {
  let sent = fn(problem) { testing.failure(message.Google, problem).sent }
  sent(error.Provider(Some("INTERNAL"), "x"))
  |> should.equal(llm_wire.Completed)
  sent(error.Cancelled) |> should.equal(llm_wire.MaybeSent)
  sent(error.DeadlineExceeded(error.IdleGap))
  |> should.equal(llm_wire.MaybeSent)
  sent(
    error.Http(http_error.new(
      http_error.RequestFailed(http_error.ConnectionReset),
      http_error.NotSent,
    )),
  )
  |> should.equal(llm_wire.NotSent)
  sent(
    error.Http(http_error.new(
      http_error.RequestFailed(http_error.ConnectionReset),
      http_error.MaybeSent,
    )),
  )
  |> should.equal(llm_wire.MaybeSent)
}

pub fn a_built_failure_feeds_advise_and_describe_test() {
  let built = testing.failure(message.Anthropic, error.Status(529, "", None))
  llm_wire.advise(built).prospect |> should.equal(llm_wire.MayHelp)
  llm_wire.describe_failure(built)
  |> string.contains("anthropic")
  |> should.be_true
  let partial = llm_wire.Failure(..built, partial_output: True)
  partial.partial_output |> should.be_true
}

// --- in-band provider errors ---------------------------------------------------

fn error_code(provider: message.Provider) -> String {
  case provider {
    message.OpenAI -> "server_error"
    message.Anthropic -> "overloaded_error"
    message.Google -> "UNAVAILABLE"
    message.Custom(_) -> "busy"
  }
}

pub fn stream_error_fails_with_the_provider_error_after_the_content_test() {
  use #(provider, config) <- list.each(wires())
  let code = error_code(provider)
  let assert Error(failure) =
    run_in(
      config,
      testing.stream_error(provider, testing.text("partial"), code, "try again"),
    )
  failure.error |> should.equal(error.Provider(Some(code), "try again"))
  failure.provider |> should.equal(provider)
  failure.sent |> should.equal(llm_wire.Completed)
  failure.partial_output |> should.be_true
  llm_wire.advise(failure)
  |> should.equal(llm_wire.RetryAdvice(llm_wire.MayHelp, llm_wire.Backoff))
}

pub fn stream_error_codes_that_will_not_help_advise_so_in_every_wire_test() {
  use #(provider, config) <- list.each(wires())
  let code = case provider {
    message.OpenAI -> "insufficient_quota"
    message.Anthropic -> "authentication_error"
    _ -> "PERMISSION_DENIED"
  }
  let assert Error(failure) =
    run_in(
      config,
      testing.stream_error(provider, testing.text("x"), code, "no"),
    )
  failure.error |> should.equal(error.Provider(Some(code), "no"))
  llm_wire.advise(failure).prospect
  |> should.equal(llm_wire.WillNotHelpUnchanged)
}

pub fn stream_error_streams_the_content_first_in_every_wire_test() {
  use #(provider, config) <- list.each(wires())
  let assert Ok(prepared) = llm_wire.prepare(config, hi())
  use client <- http_test_helpers.with_script([
    testing.exchange(
      prepared,
      testing.stream_error(provider, testing.text("seen"), "x", "y"),
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
  |> should.equal("seen")
  let assert Error(_) = outcome
}

pub fn stream_error_works_on_the_scripted_wire_test() {
  let provider = message.Custom("scripted")
  let assert Error(failure) =
    run_in(
      testing.config(),
      testing.stream_error(provider, testing.text("p"), "busy", "later"),
    )
  failure.error |> should.equal(error.Provider(Some("busy"), "later"))
  failure.partial_output |> should.be_true
}

pub fn stream_error_leaves_status_and_interrupted_replies_alone_test() {
  let status = testing.http_status(message.Custom("scripted"), 503, "busy")
  testing.stream_error(message.OpenAI, status, "a", "b")
  |> should.equal(status)
  let cut = testing.interrupted(testing.events(["x"]))
  testing.stream_error(message.OpenAI, cut, "a", "b") |> should.equal(cut)
}

// --- OpenAI response.failed and response.incomplete -------------------------------

fn openai_config() -> llm_wire.Config {
  openai.new("k") |> openai.config
}

pub fn response_failed_carries_the_error_code_and_message_test() {
  let assert Error(failure) =
    run_in(
      openai_config(),
      testing.response_failed(testing.text("part"), "server_error", "boom"),
    )
  failure.error |> should.equal(error.Provider(Some("server_error"), "boom"))
  failure.sent |> should.equal(llm_wire.Completed)
  failure.partial_output |> should.be_true
  llm_wire.advise(failure)
  |> should.equal(llm_wire.RetryAdvice(llm_wire.MayHelp, llm_wire.Backoff))
}

pub fn response_failed_classifies_like_an_error_event_test() {
  let advice = fn(reply) {
    let assert Error(failure) = run_in(openai_config(), reply)
    #(failure.error, llm_wire.advise(failure))
  }
  list.each(
    [
      "rate_limit_exceeded",
      "server_is_overloaded",
      "insufficient_quota",
      "invalid_prompt",
      "something_new",
    ],
    fn(code) {
      let failed = advice(testing.response_failed(testing.text("x"), code, "m"))
      let errored =
        advice(testing.stream_error(
          message.OpenAI,
          testing.text("x"),
          code,
          "m",
        ))
      failed |> should.equal(errored)
    },
  )
}

pub fn response_failed_without_an_error_object_still_fails_test() {
  let body =
    "event: response.failed\ndata: {\"type\":\"response.failed\",\"response\":{\"id\":\"r\",\"status\":\"failed\",\"error\":null}}\n\n"
  let assert Error(failure) = run_in(openai_config(), testing.events([body]))
  let assert error.Provider(None, text) = failure.error
  string.contains(text, "failed") |> should.be_true
}

pub fn a_completed_event_with_status_failed_reads_the_error_too_test() {
  let body =
    "event: response.completed\ndata: {\"response\":{\"id\":\"r\",\"status\":\"failed\",\"error\":{\"code\":\"server_error\",\"message\":\"late\"}}}\n\n"
  let assert Error(failure) = run_in(openai_config(), testing.events([body]))
  failure.error |> should.equal(error.Provider(Some("server_error"), "late"))
}

pub fn response_incomplete_is_an_output_limit_test() {
  let body =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"i\",\"delta\":\"cut\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"message\"}}\n\n"
    <> "event: response.incomplete\ndata: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"r\",\"status\":\"incomplete\",\"error\":null,\"incomplete_details\":{\"reason\":\"max_output_tokens\"}}}\n\n"
  let assert Ok(llm_wire.OutputLimited(partial_text: "cut", ..)) =
    run_in(openai_config(), testing.events([body]))
}

fn incomplete(reason: String) -> String {
  "event: response.incomplete\ndata: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"r\",\"status\":\"incomplete\",\"error\":null,\"incomplete_details\":{\"reason\":\""
  <> reason
  <> "\"}}}\n\n"
}

pub fn response_incomplete_by_the_content_filter_is_not_an_output_limit_test() {
  let assert Error(failure) =
    run_in(openai_config(), testing.events([incomplete("content_filter")]))
  failure.error
  |> should.equal(error.ContentFiltered(error.InOutput, "content_filter"))
  failure.sent |> should.equal(llm_wire.Completed)
  llm_wire.advise(failure).prospect
  |> should.equal(llm_wire.WillNotHelpUnchanged)
}

pub fn response_incomplete_with_an_unknown_reason_is_a_provider_error_test() {
  let assert Error(failure) =
    run_in(openai_config(), testing.events([incomplete("something_new")]))
  let assert error.Provider(Some("something_new"), _) = failure.error
  llm_wire.advise(failure).prospect |> should.equal(llm_wire.Unknown)
}

pub fn response_incomplete_without_details_is_still_an_output_limit_test() {
  let body =
    "event: response.incomplete\ndata: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"r\",\"status\":\"incomplete\",\"incomplete_details\":null}}\n\n"
  let assert Ok(llm_wire.OutputLimited(partial_text: "", ..)) =
    run_in(openai_config(), testing.events([body]))
}

// --- content filters ------------------------------------------------------------

pub fn content_filtered_fails_in_every_wire_with_the_wires_reason_test() {
  use #(provider, config) <- list.each([
    #(message.Custom("scripted"), testing.config()),
    ..wires()
  ])
  let assert Error(failure) =
    run_in(config, testing.content_filtered("I was say"))
  let reason = case provider {
    message.OpenAI -> "content_filter"
    message.Anthropic -> "refusal"
    message.Google -> "SAFETY"
    message.Custom(_) -> "content_filter"
  }
  failure.error |> should.equal(error.ContentFiltered(error.InOutput, reason))
  failure.sent |> should.equal(llm_wire.Completed)
  failure.partial_output |> should.be_true
  failure.provider |> should.equal(provider)
  llm_wire.advise(failure)
  |> should.equal(llm_wire.RetryAdvice(
    llm_wire.WillNotHelpUnchanged,
    llm_wire.Backoff,
  ))
  error.kind(failure.error) |> should.equal(error.ContentPolicy)
}

pub fn prompt_blocked_fails_on_gemini_and_the_scripted_wire_test() {
  let wires = [
    #(message.Google, "SAFETY", google.new("k") |> google.config),
    #(message.Custom("scripted"), "content_filter", testing.config()),
  ]
  use #(provider, reason, config) <- list.each(wires)
  let assert Error(failure) = run_in(config, testing.prompt_blocked())
  failure.error |> should.equal(error.ContentFiltered(error.InPrompt, reason))
  failure.partial_output |> should.be_false
  failure.provider |> should.equal(provider)
  llm_wire.advise(failure).prospect
  |> should.equal(llm_wire.WillNotHelpUnchanged)
}

pub fn every_gemini_filter_finish_reason_is_content_filtered_test() {
  use reason <- list.each([
    "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII",
    "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT",
  ])
  let body =
    "data: {\"candidates\":[{\"finishReason\":\""
    <> reason
    <> "\",\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"so\"}]}}]}\n\n"
  let assert Error(failure) =
    run_in(google.new("k") |> google.config, testing.events([body]))
  failure.error |> should.equal(error.ContentFiltered(error.InOutput, reason))
}

pub fn every_gemini_block_reason_is_a_blocked_prompt_test() {
  use reason <- list.each([
    "SAFETY", "OTHER", "BLOCKLIST", "PROHIBITED_CONTENT", "IMAGE_SAFETY",
  ])
  let body =
    "data: {\"promptFeedback\":{\"blockReason\":\"" <> reason <> "\"}}\n\n"
  let assert Error(failure) =
    run_in(google.new("k") |> google.config, testing.events([body]))
  failure.error |> should.equal(error.ContentFiltered(error.InPrompt, reason))
}

pub fn a_lowered_reply_is_not_lowered_again_test() {
  use #(provider, config) <- list.each(wires())
  let once = testing.events_for(provider, testing.text("hi"))
  testing.events_for(provider, once) |> should.equal(once)
  testing.with_usage(once, message.Usage(1, 1, 2)) |> should.equal(once)
  let assert Ok(llm_wire.Answer(text: "hi", ..)) = run_in(config, once)
}

pub fn exchange_lowers_a_scripted_reply_into_the_prepared_wire_test() {
  use #(_, config) <- list.each(wires())
  let assert Ok(llm_wire.Answer(text: "direct", ..)) =
    run_in(config, testing.text("direct"))
}

pub fn accessors_read_what_a_server_sends_test() {
  let reply = testing.text("hi")
  testing.status(reply) |> should.equal(200)
  testing.is_interrupted(reply) |> should.be_false
  testing.is_interrupted(testing.interrupted(reply)) |> should.be_true
  let limited = testing.rate_limited(message.OpenAI)
  testing.status(limited) |> should.equal(429)
  testing.is_interrupted(limited) |> should.be_false
  let assert [body] = testing.chunks(limited)
  testing.http_response(message.OpenAI, limited).body |> should.equal(body)
  testing.chunks(testing.events(["a", "b"])) |> should.equal(["a", "b"])
}

pub fn response_failed_leaves_status_and_interrupted_replies_alone_test() {
  let status = testing.http_status(message.Custom("scripted"), 503, "busy")
  testing.response_failed(status, "a", "b") |> should.equal(status)
}

pub fn a_fake_server_response_carries_retry_after_test() {
  let http =
    testing.http_response(message.OpenAI, testing.rate_limited(message.OpenAI))
    |> testing.with_retry_after_header(duration.milliseconds(1500))
  http.status |> should.equal(429)
  http.headers |> list.key_find("retry-after") |> should.equal(Ok("2"))
  http.headers
  |> list.key_find("content-type")
  |> should.equal(Ok("application/json"))
}
