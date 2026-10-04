//// Tool-call admission through the public run/stream path: strict rejection
//// by default and per-call issues when the caller opts in. Scripted
//// transports replace the network; the built-in reducers still decode their
//// own SSE. Issues moved from the assistant turn to `NeedsTools.issues`,
//// and an issue's reason is a typed `error.ValueFailure` now.

import conversation_fixture
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import http_test_helpers
import json/blueprint/codec
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/google
import llm_wire/limit
import llm_wire/message
import llm_wire/openai
import llm_wire/testing
import llm_wire/tool
import tool_fixtures

fn lookup_request() -> llm_wire.Request(String) {
  llm_wire.request("checks-model", [llm_wire.user("Find gleam")])
  |> llm_wire.with_tools([tool_fixtures.string_field_tool("lookup", "query")])
}

fn report(settings: llm_wire.Config) -> llm_wire.Config {
  llm_wire.with_tool_call_checks(settings, tool.ReportInvalidToolCalls)
}

/// One valid call, one undeclared tool, and one schema-invalid argument set.
fn mixed_calls() -> List(testing.ScriptedCall) {
  [
    testing.tool_call("call_ok", "lookup", "{\"query\":\"gleam\"}"),
    testing.tool_call("call_unknown", "missing", "{}"),
    testing.tool_call("call_bad", "lookup", "{\"query\":42}"),
  ]
}

fn assert_mixed_issues(issues: List(tool.ToolCallIssue)) -> Nil {
  let assert [
    tool.UnknownTool("call_unknown"),
    tool.InvalidArguments("call_bad", error.SchemaRejected(_)) as invalid,
  ] = issues
  string.contains(tool.describe_issue(invalid), "schema validation")
  |> should.be_true
}

fn call_ids(turn: message.AssistantTurn) -> List(String) {
  list.map(turn.calls, fn(c) { c.id })
}

pub fn strict_checks_are_the_default_for_unknown_tools_test() {
  let assert Ok(prepared) = llm_wire.prepare(testing.config(), lookup_request())
  let assert Error(failure) =
    http_test_helpers.run_reply(
      prepared,
      testing.tool_calls("", [testing.tool_call("call_1", "missing", "{}")]),
    )
  let assert error.Protocol(reason) = failure.error
  string.contains(reason, "admitted catalog") |> should.be_true
  // Content that fails admission was a completed response.
  failure.sent |> should.equal(llm_wire.Completed)
}

pub fn strict_checks_reject_schema_invalid_arguments_test() {
  let assert Ok(prepared) = llm_wire.prepare(testing.config(), lookup_request())
  let assert Error(failure) =
    http_test_helpers.run_reply(
      prepared,
      testing.tool_calls("", [
        testing.tool_call("call_1", "lookup", "{\"query\":42}"),
      ]),
    )
  let assert error.Protocol(reason) = failure.error
  string.contains(reason, "schema validation") |> should.be_true
}

pub fn reported_issues_keep_every_call_in_order_test() {
  let assert Ok(prepared) =
    llm_wire.prepare(report(testing.config()), lookup_request())

  let assert Ok(llm_wire.NeedsTools(turn:, issues:, usage: None)) =
    http_test_helpers.run_reply(
      prepared,
      testing.tool_calls("Checking.", mixed_calls()),
    )
  turn.text |> should.equal("Checking.")
  call_ids(turn) |> should.equal(["call_ok", "call_unknown", "call_bad"])
  assert_mixed_issues(issues)

  // Every call, including an invalid one, needs exactly one result.
  let partial = [
    #("call_ok", "gleam.run"),
    #("call_unknown", "{\"error\":\"unknown_tool\"}"),
  ]
  llm_wire.prepare(
    report(testing.config()),
    conversation_fixture.append_results(lookup_request(), turn, partial),
  )
  |> should.equal(
    Error(error.ToolResultMismatch("call_bad", error.MissingResult)),
  )
  let results =
    list.append(partial, [#("call_bad", "{\"error\":\"invalid_arguments\"}")])
  let assert Ok(next) =
    llm_wire.prepare(
      report(testing.config()),
      conversation_fixture.append_results(lookup_request(), turn, results),
    )
  http_test_helpers.run_reply(next, testing.text("Done."))
  |> should.equal(Ok(llm_wire.Answer("Done.", "Done.", None)))

  conversation_fixture.append_results(lookup_request(), turn, results)
  |> llm_wire.messages
  |> should.equal([
    llm_wire.user("Find gleam"),
    message.Assistant(turn),
    ..list.map(results, fn(result) { message.ToolResult(result.0, result.1) })
  ])
}

pub fn valid_calls_report_no_issues_test() {
  let assert Ok(prepared) =
    llm_wire.prepare(report(testing.config()), lookup_request())
  let assert Ok(llm_wire.NeedsTools(turn:, issues:, ..)) =
    http_test_helpers.run_reply(
      prepared,
      testing.tool_calls("", [
        testing.tool_call("call_1", "lookup", "{\"query\":\"gleam\"}"),
      ]),
    )
  list.length(turn.calls) |> should.equal(1)
  issues |> should.equal([])
}

/// Read a stream to its end, skipping progress.
fn terminal(
  stream: llm_wire.Stream(o),
) -> Result(llm_wire.Outcome(o), llm_wire.Failure) {
  case llm_wire.next(stream) {
    Ok(llm_wire.Progress(_)) -> terminal(stream)
    Ok(llm_wire.Done(result)) -> result
    Error(_) -> panic as "stream read failed"
  }
}

fn stream_reply(
  prepared: llm_wire.Prepared(o),
  reply: testing.Reply,
) -> Result(llm_wire.Outcome(o), llm_wire.Failure) {
  use client <- http_test_helpers.with_script([
    testing.exchange(prepared, reply),
  ])
  let assert Ok(stream) = llm_wire.stream(client, prepared)
  terminal(stream)
}

pub fn streamed_and_buffered_paths_report_the_same_issues_test() {
  let settings = report(testing.config())
  let assert Ok(buffered) = llm_wire.prepare(settings, lookup_request())
  let assert Ok(streamed) = llm_wire.prepare(settings, lookup_request())

  let assert Ok(llm_wire.NeedsTools(
    turn: buffered_turn,
    issues: buffered_issues,
    ..,
  )) =
    http_test_helpers.run_reply(buffered, testing.tool_calls("", mixed_calls()))
  let assert Ok(llm_wire.NeedsTools(
    turn: streamed_turn,
    issues: streamed_issues,
    ..,
  )) = stream_reply(streamed, testing.tool_calls("", mixed_calls()))

  streamed_turn.calls |> should.equal(buffered_turn.calls)
  streamed_issues |> should.equal(buffered_issues)
  assert_mixed_issues(streamed_issues)
}

pub fn structured_calls_report_issues_test() {
  let request =
    lookup_request()
    |> llm_wire.with_output(
      "answer",
      tool_fixtures.one_field("answer", codec.string()),
    )
  let assert Ok(prepared) = llm_wire.prepare(report(testing.config()), request)
  let assert Ok(llm_wire.NeedsTools(turn:, issues:, ..)) =
    http_test_helpers.run_reply(prepared, testing.tool_calls("", mixed_calls()))
  list.length(turn.calls) |> should.equal(3)
  assert_mixed_issues(issues)
}

pub fn reporting_keeps_bounds_and_identity_fatal_test() {
  let settings = report(testing.config())
  let assert Ok(oversized) =
    llm_wire.prepare(
      llm_wire.with_limit(settings, limit.ArgumentBytesPerCall, 16),
      lookup_request(),
    )
  let assert Ok(duplicate) = llm_wire.prepare(settings, lookup_request())
  let assert Ok(unnamed) = llm_wire.prepare(settings, lookup_request())

  let assert Error(failure) =
    http_test_helpers.run_reply(
      oversized,
      testing.tool_calls("", [
        testing.tool_call("call_1", "lookup", "{\"query\":\"far too long\"}"),
      ]),
    )
  let assert error.LimitExceeded(limit.ArgumentBytesPerCall, 16, _) =
    failure.error
  let assert Error(failure) =
    http_test_helpers.run_reply(
      duplicate,
      testing.tool_calls("", [
        testing.tool_call("call_1", "lookup", "{}"),
        testing.tool_call("call_1", "lookup", "{}"),
      ]),
    )
  let assert error.Protocol(_) = failure.error
  let assert Error(failure) =
    http_test_helpers.run_reply(
      unnamed,
      testing.tool_calls("", [testing.tool_call("call_1", "look.up", "{}")]),
    )
  let assert error.Protocol(reason) = failure.error
  string.contains(reason, "invalid tool name") |> should.be_true
}

// Built-in reducers decode calls; the runtime alone decides admission.

fn built_in_settings() -> List(#(message.Provider, llm_wire.Config)) {
  [
    #(message.OpenAI, openai.new("sk-scripted") |> openai.config),
    #(message.Anthropic, anthropic.new("sk-scripted") |> anthropic.config),
    #(message.Google, google.new("sk-scripted") |> google.config),
  ]
}

pub fn built_in_providers_report_per_call_issues_test() {
  list.each(built_in_settings(), fn(entry) {
    let #(wire, settings) = entry
    let assert Ok(prepared) =
      llm_wire.prepare(settings |> report, lookup_request())
    case
      http_test_helpers.run_reply(
        prepared,
        testing.events_for(wire, testing.tool_calls("", mixed_calls())),
      )
    {
      Ok(llm_wire.NeedsTools(turn:, issues:, ..)) -> {
        call_ids(turn) |> should.equal(["call_ok", "call_unknown", "call_bad"])
        assert_mixed_issues(issues)
      }
      other ->
        panic as { message.provider_name(wire) <> ": " <> string.inspect(other) }
    }
  })
}

pub fn built_in_providers_reject_invalid_calls_by_default_test() {
  list.each(built_in_settings(), fn(entry) {
    let #(wire, settings) = entry
    let assert Ok(prepared) = llm_wire.prepare(settings, lookup_request())
    case
      http_test_helpers.run_reply(
        prepared,
        testing.events_for(wire, testing.tool_calls("", mixed_calls())),
      )
    {
      Error(llm_wire.Failure(error: error.Protocol(_), ..)) -> Nil
      other ->
        panic as { message.provider_name(wire) <> ": " <> string.inspect(other) }
    }
  })
}

pub fn invalid_json_arguments_follow_the_selected_checks_test() {
  let calls = [testing.tool_call("call_1", "lookup", "{not valid")]
  let wires = [
    #(message.OpenAI, openai.new("sk-scripted") |> openai.config),
    #(message.Anthropic, anthropic.new("sk-scripted") |> anthropic.config),
  ]
  list.each(wires, fn(entry) {
    let #(wire, strict) = entry
    let reply = testing.events_for(wire, testing.tool_calls("", calls))
    let assert Ok(rejected) = llm_wire.prepare(strict, lookup_request())
    let assert Ok(reported) = llm_wire.prepare(report(strict), lookup_request())

    // The reason is the runtime's admission message, naming the typed
    // `InvalidJson` failure, instead of a fixed reducer string.
    let assert Error(failure) = http_test_helpers.run_reply(rejected, reply)
    let assert error.Protocol(reason) = failure.error
    string.starts_with(
      reason,
      "Tool call lookup has invalid arguments: invalid JSON",
    )
    |> should.be_true
    let assert Ok(llm_wire.NeedsTools(issues:, ..)) =
      http_test_helpers.run_reply(reported, reply)
    let assert [tool.InvalidArguments("call_1", error.InvalidJson(_))] = issues
  })
}

// A call the runtime reported must replay to its provider on the next request,
// from the returned assistant turn, without caller rewriting.

/// Truncated argument text, as a provider cut off mid-call returns it.
const truncated = "{\"query\": "

/// A provider, a reply holding one valid call and one invalid call, and the
/// wire form each call must take when replayed.
type ReplayCase {
  ReplayCase(
    name: String,
    settings: llm_wire.Config,
    calls_reply: testing.Reply,
    text_reply: testing.Reply,
    replayed_valid: String,
    replayed_invalid: String,
  )
}

fn wrapped(text: String) -> String {
  "{\"unparsed_arguments\":" <> json.to_string(json.string(text)) <> "}"
}

/// Gemini carries arguments as a JSON value; `testing.events_for` sends
/// only objects, so this body sends a value that is not an object.
/// Each call is `#(id, name, arguments_json)`.
fn google_body(calls: List(#(String, String, String))) -> String {
  let parts =
    list.map(calls, fn(c) {
      let #(id, name, arguments_json) = c
      "{\"functionCall\":{\"name\":\""
      <> name
      <> "\",\"id\":\""
      <> id
      <> "\",\"args\":"
      <> arguments_json
      <> "}}"
    })
  "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":["
  <> string.join(parts, ",")
  <> "]},\"finishReason\":\"STOP\"}]}\n\n"
}

fn replay_cases() -> List(ReplayCase) {
  let valid = testing.tool_call("call_ok", "lookup", "{\"query\":\"gleam\"}")
  let cut = testing.tool_call("call_bad", "lookup", truncated)
  let replies = fn(wire) {
    #(
      testing.events_for(wire, testing.tool_calls("", [valid, cut])),
      testing.events_for(wire, testing.text("ok")),
    )
  }
  let #(openai_calls, openai_text) = replies(message.OpenAI)
  let #(anthropic_calls, anthropic_text) = replies(message.Anthropic)
  // Google's malformed form is a value that is not an object; the reducer
  // keeps its JSON text.
  let google_bad = json.to_string(json.string(truncated))
  [
    ReplayCase(
      "openai",
      openai.new("sk-scripted") |> openai.config,
      openai_calls,
      openai_text,
      "\"arguments\":" <> json.to_string(json.string("{\"query\":\"gleam\"}")),
      "\"arguments\":" <> json.to_string(json.string(truncated)),
    ),
    ReplayCase(
      "anthropic",
      anthropic.new("sk-scripted") |> anthropic.config,
      anthropic_calls,
      anthropic_text,
      "\"input\":{\"query\":\"gleam\"}",
      "\"input\":" <> wrapped(truncated),
    ),
    ReplayCase(
      "google",
      google.new("sk-scripted") |> google.config,
      testing.events([
        google_body([
          #("call_ok", "lookup", "{\"query\":\"gleam\"}"),
          #("call_bad", "lookup", google_bad),
        ]),
      ]),
      testing.events_for(message.Google, testing.text("ok")),
      "\"args\":{\"query\":\"gleam\"}",
      "\"args\":" <> wrapped(google_bad),
    ),
  ]
}

fn replay_results() -> List(#(String, String)) {
  [
    #("call_ok", "gleam.run"),
    #("call_bad", "{\"error\":\"invalid_arguments\"}"),
  ]
}

fn assert_replayed(case_: ReplayCase, body: String) -> Nil {
  case
    string.contains(body, case_.replayed_valid),
    string.contains(body, case_.replayed_invalid)
  {
    True, True -> Nil
    _, _ -> panic as { case_.name <> " replayed: " <> body }
  }
}

fn assert_reported_bad_call(
  case_: ReplayCase,
  issues: List(tool.ToolCallIssue),
) -> Nil {
  case issues {
    [tool.InvalidArguments("call_bad", _)] -> Nil
    _ -> panic as { case_.name <> " issues: " <> string.inspect(issues) }
  }
}

pub fn reported_calls_replay_from_buffered_assistant_turn_test() {
  list.each(replay_cases(), fn(case_) {
    let settings = case_.settings |> report
    let assert Ok(prepared) = llm_wire.prepare(settings, lookup_request())
    let assert Ok(llm_wire.NeedsTools(turn:, issues:, ..)) =
      http_test_helpers.run_reply(prepared, case_.calls_reply)
    assert_reported_bad_call(case_, issues)

    case
      llm_wire.prepare(
        settings,
        conversation_fixture.append_results(
          lookup_request(),
          turn,
          replay_results(),
        ),
      )
    {
      Ok(next) -> {
        let assert Ok(llm_wire.Answer(..)) =
          http_test_helpers.run_reply(next, case_.text_reply)
        assert_replayed(case_, llm_wire.request_json(next))
      }
      Error(problem) ->
        panic as { case_.name <> ": " <> string.inspect(problem) }
    }
  })
}

pub fn reported_calls_replay_from_streamed_assistant_turn_test() {
  list.each(replay_cases(), fn(case_) {
    let settings = case_.settings |> report
    let assert Ok(prepared) = llm_wire.prepare(settings, lookup_request())
    let assert Ok(llm_wire.NeedsTools(turn:, issues:, ..)) =
      stream_reply(prepared, case_.calls_reply)
    assert_reported_bad_call(case_, issues)

    case
      llm_wire.prepare(
        settings,
        conversation_fixture.append_results(
          lookup_request(),
          turn,
          replay_results(),
        ),
      )
    {
      Ok(next) -> {
        let assert Ok(llm_wire.Answer(..)) =
          stream_reply(next, case_.text_reply)
        assert_replayed(case_, llm_wire.request_json(next))
      }
      Error(problem) ->
        panic as { case_.name <> ": " <> string.inspect(problem) }
    }
  })
}

pub fn reported_calls_replay_from_public_messages_test() {
  list.each(replay_cases(), fn(case_) {
    // The caller persisted the first round's calls and rebuilds the request.
    let assert Ok(prepared) =
      llm_wire.prepare(case_.settings |> report, lookup_request())
    let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
      http_test_helpers.run_reply(prepared, case_.calls_reply)

    let request =
      llm_wire.request("checks-model", [
        llm_wire.user("Find gleam"),
        message.Assistant(turn),
        ..list.map(replay_results(), fn(result) {
          message.ToolResult(result.0, result.1)
        })
      ])
      |> llm_wire.with_tools([
        tool_fixtures.string_field_tool("lookup", "query"),
      ])
    case llm_wire.prepare(case_.settings |> report, request) {
      Ok(next) -> {
        let assert Ok(llm_wire.Answer(..)) =
          http_test_helpers.run_reply(next, case_.text_reply)
        assert_replayed(case_, llm_wire.request_json(next))
      }
      Error(problem) ->
        panic as { case_.name <> ": " <> string.inspect(problem) }
    }
  })
}

pub fn reported_call_replies_still_fail_default_checks_test() {
  list.each(replay_cases(), fn(case_) {
    let assert Ok(prepared) = llm_wire.prepare(case_.settings, lookup_request())
    case http_test_helpers.run_reply(prepared, case_.calls_reply) {
      Error(llm_wire.Failure(error: error.Protocol(_), ..)) -> Nil
      other -> panic as { case_.name <> ": " <> string.inspect(other) }
    }
  })
}

/// The replay encoding belongs to the transcript, not to response admission:
/// a rebuilt request encodes the same way under either checks setting.
pub fn replay_encoding_does_not_depend_on_the_checks_setting_test() {
  list.each(replay_cases(), fn(case_) {
    let calls = [
      message.tool_call("call_ok", "lookup", "{\"query\":\"gleam\"}"),
      message.tool_call("call_bad", "lookup", truncated),
    ]
    let request =
      llm_wire.request("checks-model", [
        llm_wire.user("Find gleam"),
        message.Assistant(message.AssistantTurn(
          provider: None,
          text: "",
          calls:,
          response_id: None,
          provider_data: None,
        )),
        ..list.map(replay_results(), fn(result) {
          message.ToolResult(result.0, result.1)
        })
      ])
    let assert Ok(strict) = llm_wire.prepare(case_.settings, request)
    let assert Ok(reported) = llm_wire.prepare(report(case_.settings), request)
    llm_wire.request_json(strict)
    |> should.equal(llm_wire.request_json(reported))
  })
}
