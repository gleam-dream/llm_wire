//// Wave 4 facade: one execution family, typed failures, retry advice,
//// conversation codecs, built-in wire fakes and telemetry correlation.

import gleam/bit_array
import gleam/erlang/process
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/config as http_config
import http_gun/destination
import http_gun/error as http_error
import http_gun/telemetry as http_telemetry
import http_gun/testing as http_testing
import http_test_helpers
import json/blueprint/codec
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/google
import llm_wire/limit
import llm_wire/message
import llm_wire/openai
import llm_wire/telemetry
import llm_wire/testing
import llm_wire/tool
import sinal
import sinal/correlation
import tool_fixtures

type Invoice {
  Invoice(total: Int, currency: String)
}

fn invoice_codec() -> codec.Codec(Invoice) {
  use total <- codec.field("total", codec.int(), get: fn(i: Invoice) { i.total })
  use currency <- codec.field(
    "currency",
    codec.string_enum([#("EUR", "EUR"), #("USD", "USD")]),
    get: fn(i) { i.currency },
  )
  codec.success(Invoice(total:, currency:))
}

fn hello() -> llm_wire.Request(String) {
  llm_wire.request("scripted-model", [llm_wire.user("Hello")])
}

pub fn plain_answer_output_is_the_text_test() {
  let assert Ok(prepared) = llm_wire.prepare(testing.config(), hello())
  let assert Ok(llm_wire.Answer(output:, text:, usage: None)) =
    http_test_helpers.run_reply(prepared, testing.text("Hi there"))
  output |> should.equal("Hi there")
  text |> should.equal("Hi there")
}

pub fn structured_output_decodes_in_the_same_family_test() {
  let request = hello() |> llm_wire.with_output("invoice", invoice_codec())
  let assert Ok(prepared) = llm_wire.prepare(testing.config(), request)
  let assert Ok(llm_wire.Answer(output:, ..)) =
    http_test_helpers.run_reply(
      prepared,
      testing.text("{\"total\":12,\"currency\":\"EUR\"}"),
    )
  output |> should.equal(Invoice(12, "EUR"))
}

pub fn invalid_structured_output_fails_with_raw_text_and_typed_reason_test() {
  let request = hello() |> llm_wire.with_output("invoice", invoice_codec())
  let assert Ok(prepared) = llm_wire.prepare(testing.config(), request)
  let usage = message.Usage(3, 4, 7)
  let assert Error(failure) =
    http_test_helpers.run_reply(
      prepared,
      testing.text("{\"total\":12,\"currency\":\"GBP\"}")
        |> testing.with_usage(usage),
    )
  let assert error.InvalidOutput(raw_output:, failure: error.SchemaRejected(_)) =
    failure.error
  raw_output |> should.equal("{\"total\":12,\"currency\":\"GBP\"}")
  failure.sent |> should.equal(llm_wire.Completed)
  failure.usage |> should.equal(Some(usage))
  let assert Error(not_json) =
    http_test_helpers.run_reply(prepared, testing.text("not json"))
  let assert error.InvalidOutput("not json", error.InvalidJson(_)) =
    not_json.error
  error.name(not_json.error) |> should.equal("invalid_output.invalid_json")
}

pub fn an_output_codec_without_schema_fails_preparation_test() {
  let custom =
    codec.custom(
      encode: fn(_) { Error(codec.encode_failure("no")) },
      decode: fn(_) { Error(codec.decode_failure("no")) },
      schema: None,
      placeholder: Nil,
    )
  let request = hello() |> llm_wire.with_output("thing", custom)
  let assert Error(error.UnsupportedSchema(error.Output, _)) =
    llm_wire.prepare(testing.config(), request)
}

pub fn tool_loop_appends_the_turn_and_results_test() {
  let lookup = tool_fixtures.string_field_tool("lookup", "query")
  let request = hello() |> llm_wire.with_tools([lookup])
  let assert Ok(prepared) = llm_wire.prepare(testing.config(), request)
  let assert Ok(llm_wire.NeedsTools(turn:, issues: [], ..)) =
    http_test_helpers.run_reply(
      prepared,
      testing.tool_calls("Looking", [
        testing.tool_call("call_1", "lookup", "{\"query\":\"x\"}"),
      ]),
    )
  turn.provider |> should.equal(Some(message.Custom("scripted")))
  let assert [call] = turn.calls
  tool.decode_arguments(call, tool_fixtures.one_field("query", codec.string()))
  |> should.equal(Ok("x"))
  let next =
    llm_wire.append(request, [
      message.Assistant(turn),
      llm_wire.tool_result(call, "{\"found\":true}"),
    ])
  let assert Ok(_) = llm_wire.prepare(testing.config(), next)
  // A missing result is a typed preparation error.
  let assert Error(error.ToolResultMismatch("call_1", error.MissingResult)) =
    llm_wire.prepare(
      testing.config(),
      llm_wire.append(request, [message.Assistant(turn)]),
    )
}

pub fn reported_invalid_calls_carry_a_typed_reason_test() {
  let lookup = tool_fixtures.int_field_tool("lookup", "n")
  let config =
    testing.config()
    |> llm_wire.with_tool_call_checks(tool.ReportInvalidToolCalls)
  let assert Ok(prepared) =
    llm_wire.prepare(config, hello() |> llm_wire.with_tools([lookup]))
  let assert Ok(llm_wire.NeedsTools(issues:, ..)) =
    http_test_helpers.run_reply(
      prepared,
      testing.tool_calls("", [
        testing.tool_call("a", "lookup", "{\"n\":\"one\"}"),
        testing.tool_call("b", "ghost", "{}"),
      ]),
    )
  let assert [
    tool.InvalidArguments("a", error.SchemaRejected(_)),
    tool.UnknownTool("b"),
  ] = issues
  list.map(issues, tool.describe_issue)
  |> list.all(fn(text) { text != "" })
  |> should.be_true
}

pub fn stream_reports_tool_argument_progress_test() {
  let lookup = tool_fixtures.string_field_tool("lookup", "query")
  let assert Ok(prepared) =
    llm_wire.prepare(testing.config(), hello() |> llm_wire.with_tools([lookup]))
  let reply =
    testing.tool_calls("", [
      testing.tool_call("call_1", "lookup", "{\"query\":\"x\"}"),
    ])
  use client <- http_test_helpers.with_script([
    testing.exchange(prepared, reply),
  ])
  let assert Ok(stream) = llm_wire.stream(client, prepared)
  let assert Ok(llm_wire.Progress(message.ToolArgumentsDelta(
    "call_1",
    "{\"query\":\"x\"}",
  ))) = llm_wire.next(stream)
  let assert Ok(llm_wire.Done(Ok(llm_wire.NeedsTools(..)))) =
    llm_wire.next(stream)
  llm_wire.next(stream) |> should.equal(Error(llm_wire.StreamEnded))
  llm_wire.close(stream) |> should.equal(llm_wire.AlreadyEnded)
}

pub fn preparation_errors_are_typed_test() {
  let assert Error(error.InvalidSetting(error.Model, _)) =
    llm_wire.prepare(testing.config(), llm_wire.request(" ", []))
  let assert Error(error.InvalidSetting(error.ApiKey, _)) =
    llm_wire.prepare(openai.new("  ") |> openai.config, hello())
  let assert Error(error.InvalidSetting(error.LimitSetting(limit.EventBytes), _)) =
    llm_wire.prepare(
      testing.config() |> llm_wire.with_limit(limit.EventBytes, 0),
      hello(),
    )
  let assert Error(error.InvalidSetting(error.TimeoutSetting(error.IdleGap), _)) =
    llm_wire.prepare(
      testing.config()
        |> llm_wire.with_idle_timeout(llm_wire.After(duration.seconds(0))),
      hello(),
    )
  let assert Error(error.InvalidSetting(error.Endpoint, _)) =
    llm_wire.prepare(
      testing.config() |> llm_wire.with_endpoint("ftp://x"),
      hello(),
    )
  let assert Error(error.InvalidRequest(error.MaxTokensNotPositive)) =
    llm_wire.prepare(testing.config(), hello() |> llm_wire.with_max_tokens(0))
  let assert Error(error.InvalidRequest(error.StopSequencesUnsupported)) =
    llm_wire.prepare(
      openai.new("k") |> openai.config,
      hello() |> llm_wire.with_stop_sequences(["x"]),
    )
  let assert Error(error.RequestTooLarge(limit.RequestBytes, 10, _)) =
    llm_wire.prepare(
      testing.config() |> llm_wire.with_limit(limit.RequestBytes, 10),
      hello(),
    )
  let assert Error(error.ToolResultMismatch("x", error.NoPrecedingCalls)) =
    llm_wire.prepare(
      testing.config(),
      llm_wire.request("m", [message.ToolResult("x", "r")]),
    )
  let lookup = tool_fixtures.string_field_tool("lookup", "q")
  let assert Error(error.InvalidRequest(error.DuplicateToolName("lookup"))) =
    llm_wire.prepare(
      testing.config(),
      hello() |> llm_wire.with_tools([lookup, lookup]),
    )
}

pub fn infinity_lifts_a_timeout_test() {
  let config =
    testing.config()
    |> llm_wire.with_call_timeout(llm_wire.Infinity)
    |> llm_wire.with_first_token_timeout(llm_wire.Infinity)
    |> llm_wire.with_idle_timeout(llm_wire.Infinity)
  let assert Ok(prepared) = llm_wire.prepare(config, hello())
  let assert Ok(llm_wire.Answer(text: "ok", ..)) =
    http_test_helpers.run_reply(prepared, testing.text("ok"))
}

// --- built-in wire fakes -----------------------------------------------------

fn builtin_configs() -> List(#(message.Provider, llm_wire.Config)) {
  [
    #(message.OpenAI, openai.new("k") |> openai.config),
    #(message.Anthropic, anthropic.new("k") |> anthropic.config),
    #(message.Google, google.new("k") |> google.config),
  ]
}

pub fn events_for_lowers_text_into_every_builtin_wire_test() {
  use #(provider, config) <- list.each(builtin_configs())
  let assert Ok(prepared) = llm_wire.prepare(config, hello())
  let reply =
    testing.text("Bonjour") |> testing.with_usage(message.Usage(2, 3, 5))
  let assert Ok(llm_wire.Answer(text: "Bonjour", usage: Some(usage), ..)) =
    http_test_helpers.run_reply(prepared, testing.events_for(provider, reply))
  usage.output_tokens |> should.equal(3)
}

pub fn events_for_lowers_tool_calls_into_every_builtin_wire_test() {
  use #(provider, config) <- list.each(builtin_configs())
  let lookup = tool_fixtures.string_field_tool("lookup", "query")
  let assert Ok(prepared) =
    llm_wire.prepare(config, hello() |> llm_wire.with_tools([lookup]))
  let reply =
    testing.tool_calls("", [
      testing.tool_call("call_7", "lookup", "{\"query\":\"paris\"}"),
    ])
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
    http_test_helpers.run_reply(prepared, testing.events_for(provider, reply))
  let assert [call] = turn.calls
  call.name |> should.equal("lookup")
  tool.decode_arguments(call, tool_fixtures.one_field("query", codec.string()))
  |> should.equal(Ok("paris"))
  turn.provider |> should.equal(Some(provider))
  // The turn replays into the next request.
  let next =
    llm_wire.append(hello(), [
      message.Assistant(turn),
      llm_wire.tool_result(call, "sunny"),
    ])
  let assert Ok(_) = llm_wire.prepare(config, next)
}

pub fn events_for_lowers_content_filter_and_limit_test() {
  use #(provider, config) <- list.each(builtin_configs())
  let assert Ok(prepared) = llm_wire.prepare(config, hello())
  let assert Error(llm_wire.Failure(
    error: error.ContentFiltered(error.InOutput, _),
    ..,
  )) =
    http_test_helpers.run_reply(
      prepared,
      testing.events_for(provider, testing.content_filtered("unsa")),
    )
  let assert Ok(llm_wire.OutputLimited(partial_text: "Once", ..)) =
    http_test_helpers.run_reply(
      prepared,
      testing.events_for(provider, testing.output_limited("Once")),
    )
}

pub fn events_for_keeps_status_and_custom_replies_test() {
  testing.events_for(
    message.OpenAI,
    testing.http_status(message.Custom("scripted"), 500, "x"),
  )
  |> should.equal(testing.http_status(message.Custom("scripted"), 500, "x"))
  testing.events_for(message.Custom("x"), testing.text("a"))
  |> should.equal(testing.text("a"))
}

// --- failures and retry advice -----------------------------------------------

fn respond(
  prepared: llm_wire.Prepared(o),
  status: Int,
  headers: List(#(String, String)),
  body: String,
) -> Result(llm_wire.Outcome(o), llm_wire.Failure) {
  let reply =
    http_testing.Respond(
      list.fold(headers, response.new(status), fn(r, h) {
        response.set_header(r, h.0, h.1)
      })
        |> response.set_body([bit_array.from_string(body)]),
      http_testing.Finished([]),
    )
  use client <- http_test_helpers.with_script([
    http_testing.exchange(http_request(prepared), reply),
  ])
  llm_wire.run(client, prepared)
}

fn http_request(prepared: llm_wire.Prepared(o)) {
  // The scripted exchange records the admitted request.
  http_testing.request(testing.exchange(prepared, testing.text("")))
}

pub fn status_failures_honor_retry_after_seconds_and_dates_test() {
  let assert Ok(prepared) = llm_wire.prepare(testing.config(), hello())
  let assert Error(failure) =
    respond(prepared, 429, [#("retry-after", "7")], "{\"error\":\"slow\"}")
  let assert error.Status(429, "{\"error\":\"slow\"}", Some(_)) = failure.error
  failure.sent |> should.equal(llm_wire.Completed)
  llm_wire.advise(failure)
  |> should.equal(llm_wire.RetryAdvice(
    llm_wire.MayHelp,
    llm_wire.ProviderDelay(duration.seconds(7)),
  ))
  let assert Error(dated) =
    respond(
      prepared,
      503,
      [#("retry-after", "Wed, 21 Oct 2015 07:28:00 GMT")],
      "",
    )
  // A date in the past asks for no delay.
  llm_wire.advise(dated)
  |> should.equal(llm_wire.RetryAdvice(
    llm_wire.MayHelp,
    llm_wire.ProviderDelay(duration.seconds(0)),
  ))
  let assert Error(bad_request) = respond(prepared, 400, [], "")
  llm_wire.advise(bad_request).prospect
  |> should.equal(llm_wire.WillNotHelpUnchanged)
}

pub fn http_failures_carry_the_opaque_failure_and_kind_test() {
  let assert Ok(prepared) = llm_wire.prepare(testing.config(), hello())
  let assert Error(failure) =
    http_test_helpers.run_reply(
      prepared,
      testing.interrupted(testing.events([])),
    )
  let assert error.Http(http_failure) = failure.error
  http_error.kind(http_failure) |> should.equal(http_error.Network)
  failure.sent |> should.equal(llm_wire.MaybeSent)
  llm_wire.advise(failure).prospect |> should.equal(llm_wire.MayHelp)
  string.contains(llm_wire.describe_failure(failure), "scripted")
  |> should.be_true
}

pub fn plaintext_to_a_non_loopback_address_is_refused_before_sending_test() {
  let config =
    openai.new("secret")
    |> openai.config
    |> llm_wire.with_endpoint("http://10.1.2.3:9/v1")
  let assert Ok(prepared) = llm_wire.prepare(config, hello())
  let client_config =
    http_config.default()
    |> http_config.with_destination(
      destination.default() |> destination.allow_private,
    )
  use client <- http_test_helpers.with_settings(client_config)
  let assert Error(failure) = llm_wire.run(client, prepared)
  let assert error.Http(http_failure) = failure.error
  http_error.reason(http_failure)
  |> should.equal(
    http_error.DestinationRejected(destination.PlaintextRefused(
      destination.Private,
    )),
  )
  failure.sent |> should.equal(llm_wire.NotSent)
  llm_wire.advise(failure).prospect
  |> should.equal(llm_wire.WillNotHelpUnchanged)
}

// --- codecs ------------------------------------------------------------------

fn sample_turn() -> message.AssistantTurn {
  message.AssistantTurn(
    provider: Some(message.Custom("acme")),
    text: "Calling",
    calls: [
      message.ToolCall("c1", "lookup", "{\"q\":1}", Some("p1"), Some("sig")),
    ],
    response_id: Some("resp_1"),
    provider_data: Some("[\"raw\"]"),
  )
}

pub fn messages_round_trip_through_json_test() {
  let messages = [
    message.System("be brief"),
    message.User("hi"),
    message.UserParts([
      message.TextPart("look"),
      message.InlineImagePart("image/png", "aGk="),
      message.ImageUrlPart("https://x.test/a.png"),
    ]),
    message.Assistant(sample_turn()),
    message.AssistantParts([message.TextPart("ok")]),
    message.ToolResult("c1", "{}"),
  ]
  use original <- list.each(messages)
  json.parse(json.to_string(message.to_json(original)), message.decoder())
  |> should.equal(Ok(original))
}

pub fn turns_round_trip_and_unknown_formats_fail_test() {
  let turn = sample_turn()
  let text = json.to_string(message.turn_to_json(turn))
  string.contains(text, "\"format\":\"llm_wire.turn.v1\"") |> should.be_true
  json.parse(text, message.turn_decoder()) |> should.equal(Ok(turn))
  let future = string.replace(text, "llm_wire.turn.v1", "llm_wire.turn.v9")
  json.parse(future, message.turn_decoder()) |> should.be_error
}

/// Fabric stored `llm_wire.turn.v1` data with the text and calls kept apart
/// and an `issues` list; that data still decodes.
pub fn fabric_turn_v1_data_decodes_test() {
  let stored =
    "{\"provider\":{\"kind\":\"google\",\"name\":null},\"response_id\":\"r\",\"provider_data\":\"[]\",\"issues\":[{\"call_id\":\"c1\",\"reason\":\"bad\"}]}"
  let calls = [message.tool_call("c1", "lookup", "{}")]
  json.parse(stored, message.turn_replay_decoder("text", calls))
  |> should.equal(
    Ok(message.AssistantTurn(
      provider: Some(message.Google),
      text: "text",
      calls:,
      response_id: Some("r"),
      provider_data: Some("[]"),
    )),
  )
  let turn = sample_turn()
  json.parse(
    json.to_string(message.turn_replay_to_json(turn)),
    message.turn_replay_decoder(turn.text, turn.calls),
  )
  |> should.equal(Ok(turn))
  json.parse(
    "{\"provider\":{\"kind\":\"unknown\"},\"response_id\":null,\"provider_data\":null,\"issues\":[]}",
    message.turn_replay_decoder("", []),
  )
  |> should.be_error
}

// --- telemetry ---------------------------------------------------------------

/// The caller sets its correlation once, on the HTTP Gun view; LLM Wire
/// copies it into its own events, and HTTP Gun's events for the request
/// carry the same value.
pub fn telemetry_carries_call_and_the_view_correlation_test() {
  let subject = process.new_subject()
  let attachment =
    sinal.observe(telemetry.event(), fn(_, meta: telemetry.Metadata) {
      process.send(subject, meta)
    })
  let http_events = process.new_subject()
  let http_attachment =
    sinal.observe(http_telemetry.event(), fn(_, meta: http_telemetry.Metadata) {
      process.send(http_events, meta.correlation)
    })
  let correlation = correlation.from_key("order-42")
  let assert Ok(prepared) = llm_wire.prepare(testing.config(), hello())
  let run = fn(view) {
    use client <- http_test_helpers.with_script([
      testing.exchange(prepared, testing.text("x")),
    ])
    llm_wire.run(view(client), prepared)
  }
  let assert Ok(_) = run(http_gun.with_correlation(_, correlation))
  let events = drain(subject, [])
  let assert [first, ..] = events
  first.stage |> should.equal(telemetry.Started)
  list.all(events, fn(meta) {
    meta.correlation == Some(correlation) && meta.call == first.call
  })
  |> should.be_true
  list.any(events, fn(meta) { meta.stage == telemetry.Terminal })
  |> should.be_true
  let assert Ok(Some(http_correlation)) = process.receive(http_events, 1000)
  http_correlation |> should.equal(correlation)
  // A second execution of the same prepared call gets a new call id; a view
  // without a correlation leaves it empty.
  let assert Ok(_) = run(fn(client) { client })
  let assert [again, ..] = drain(subject, [])
  let _ = sinal.detach(attachment)
  let _ = sinal.detach(http_attachment)
  { again.call != first.call } |> should.be_true
  again.correlation |> should.equal(None)
}

fn drain(
  subject: process.Subject(telemetry.Metadata),
  acc: List(telemetry.Metadata),
) -> List(telemetry.Metadata) {
  case process.receive(subject, 50) {
    Ok(meta) -> drain(subject, [meta, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

pub fn secrets_never_print_test() {
  let config = openai.new("sk-very-secret") |> openai.config
  string.contains(string.inspect(config), "sk-very-secret") |> should.be_false
  let assert Ok(prepared) = llm_wire.prepare(config, hello())
  string.contains(string.inspect(prepared), "sk-very-secret")
  |> should.be_false
  string.contains(llm_wire.request_json(prepared), "sk-very-secret")
  |> should.be_false
}

/// LLM Wire's plaintext view only tightens the scheme rule, so a client that
/// requires a view destination still refuses a call whose view chose none.
pub fn plaintext_view_does_not_satisfy_require_view_destination_test() {
  let config =
    openai.new("secret")
    |> openai.config
    |> llm_wire.with_endpoint("http://127.0.0.1:9/v1")
  let assert Ok(prepared) = llm_wire.prepare(config, hello())
  let client_config =
    http_test_helpers.loopback_config() |> http_config.require_view_destination
  use client <- http_test_helpers.with_settings(client_config)
  let assert Error(failure) = llm_wire.run(client, prepared)
  let assert error.Http(http_failure) = failure.error
  http_error.reason(http_failure)
  |> should.equal(http_error.ViewDestinationRequired)
  failure.sent |> should.equal(llm_wire.NotSent)
}
