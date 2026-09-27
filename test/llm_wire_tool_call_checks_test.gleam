//// Tool-call admission through the public session path: strict rejection by
//// default and per-call issues when the caller opts in. Scripted transports
//// replace the network; the built-in reducers still decode their own SSE.

import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import llm_wire/config
import llm_wire/provider/anthropic
import llm_wire/provider/google
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/testing
import llm_wire/types
import tool_fixtures

fn lookup_request() -> types.Request {
  let assert Ok(model) = types.model_id("checks-model")
  types.new_request(model, [types.UserMessage("Find gleam")])
  |> types.with_tools([tool_fixtures.string_field_tool("lookup", "query")])
}

fn report(settings: config.Config) -> config.Config {
  config.with_tool_call_checks(settings, types.ReportInvalidToolCalls)
}

fn call_id(raw: String) -> types.CallId {
  let assert Ok(id) = types.call_id(raw)
  id
}

/// One valid call, one undeclared tool, and one schema-invalid argument set.
fn mixed_calls() -> List(testing.ScriptedCall) {
  [
    testing.ScriptedCall("call_ok", "lookup", "{\"query\":\"gleam\"}"),
    testing.ScriptedCall("call_unknown", "missing", "{}"),
    testing.ScriptedCall("call_bad", "lookup", "{\"query\":42}"),
  ]
}

fn assert_mixed_issues(issues: List(types.ToolCallIssue)) -> Nil {
  let assert [
    types.UnknownTool(unknown),
    types.InvalidArguments(invalid, reason),
  ] = issues
  unknown |> should.equal(call_id("call_unknown"))
  invalid |> should.equal(call_id("call_bad"))
  string.contains(reason, "schema validation") |> should.be_true
}

pub fn strict_checks_are_the_default_for_unknown_tools_test() {
  let script =
    testing.start([
      testing.tool_calls("", [testing.ScriptedCall("call_1", "missing", "{}")]),
    ])
  let assert Ok(prepared) =
    session.prepare(testing.config(script), lookup_request())

  let assert Error(session.RunFailure(types.ProtocolError(reason), _)) =
    session.run(prepared)
  string.contains(reason, "admitted catalog") |> should.be_true
}

pub fn strict_checks_reject_schema_invalid_arguments_test() {
  let script =
    testing.start([
      testing.tool_calls("", [
        testing.ScriptedCall("call_1", "lookup", "{\"query\":42}"),
      ]),
    ])
  let assert Ok(prepared) =
    session.prepare(testing.config(script), lookup_request())

  let assert Error(session.RunFailure(types.ProtocolError(reason), _)) =
    session.run(prepared)
  string.contains(reason, "schema validation") |> should.be_true
}

pub fn reported_issues_keep_every_call_in_order_test() {
  let script =
    testing.start([
      testing.tool_calls("Checking.", mixed_calls()),
      testing.text("Done."),
    ])
  let assert Ok(prepared) =
    session.prepare(report(testing.config(script)), lookup_request())

  let assert Ok(session.RunToolCalls("Checking.", calls, continuation, None)) =
    session.run(prepared)
  list.map(calls, fn(call) { types.call_id_to_string(call.id) })
  |> should.equal(["call_ok", "call_unknown", "call_bad"])
  assert_mixed_issues(session.tool_call_issues(continuation))

  // Every call, including an invalid one, needs exactly one result.
  let partial = [
    types.ToolResult(call_id("call_ok"), "gleam.run"),
    types.ToolResult(call_id("call_unknown"), "{\"error\":\"unknown_tool\"}"),
  ]
  session.prepare_continue(continuation, partial) |> should.be_error
  let results =
    list.append(partial, [
      types.ToolResult(call_id("call_bad"), "{\"error\":\"invalid_arguments\"}"),
    ])
  let assert Ok(next) = session.prepare_continue(continuation, results)
  session.run(next) |> should.equal(Ok(session.RunText("Done.", None)))

  let assert [_, second] = testing.requests(script)
  second.request.messages
  |> should.equal([
    types.UserMessage("Find gleam"),
    types.AssistantToolCallsWithText("Checking.", calls),
    ..list.map(results, fn(result) {
      types.ToolResultMessage(result.call_id, result.content)
    })
  ])
}

pub fn valid_calls_report_no_issues_test() {
  let script =
    testing.start([
      testing.tool_calls("", [
        testing.ScriptedCall("call_1", "lookup", "{\"query\":\"gleam\"}"),
      ]),
    ])
  let assert Ok(prepared) =
    session.prepare(report(testing.config(script)), lookup_request())

  let assert Ok(session.RunToolCalls(_, [_], continuation, _)) =
    session.run(prepared)
  session.tool_call_issues(continuation) |> should.equal([])
}

pub fn streamed_and_buffered_paths_report_the_same_issues_test() {
  let script =
    testing.start([
      testing.tool_calls("", mixed_calls()),
      testing.tool_calls("", mixed_calls()),
    ])
  let settings = report(testing.config(script))
  let assert Ok(buffered) = session.prepare(settings, lookup_request())
  let assert Ok(streamed) = session.prepare(settings, lookup_request())

  let assert Ok(session.RunToolCalls(_, buffered_calls, buffered_next, _)) =
    session.run(buffered)
  let assert Ok(stream) = session.stream(streamed)
  let assert session.Finished(session.RunToolCalls(
    _,
    streamed_calls,
    streamed_next,
    _,
  )) = terminal(stream)

  streamed_calls |> should.equal(buffered_calls)
  session.tool_call_issues(streamed_next)
  |> should.equal(session.tool_call_issues(buffered_next))
  assert_mixed_issues(session.tool_call_issues(streamed_next))
}

pub fn structured_calls_report_issues_test() {
  let script = testing.start([testing.tool_calls("", mixed_calls())])
  let assert Ok(prepared) =
    session.prepare_structured(
      report(testing.config(script)),
      lookup_request(),
      "answer",
      codec.field("answer", codec.string()),
    )

  let assert Ok(session.StructuredNeedsTools(_, calls, continuation, _)) =
    session.run_structured(prepared)
  list.length(calls) |> should.equal(3)
  assert_mixed_issues(session.structured_tool_call_issues(continuation))
}

pub fn reporting_keeps_bounds_and_identity_fatal_test() {
  let limits =
    types.Limits(..types.default_limits(), argument_bytes_per_call_limit: 16)
  let script =
    testing.start([
      testing.tool_calls("", [
        testing.ScriptedCall("call_1", "lookup", "{\"query\":\"far too long\"}"),
      ]),
      testing.tool_calls("", [
        testing.ScriptedCall("call_1", "lookup", "{}"),
        testing.ScriptedCall("call_1", "lookup", "{}"),
      ]),
      testing.tool_calls("", [testing.ScriptedCall("call_1", "look.up", "{}")]),
    ])
  let settings = report(testing.config(script))
  let assert Ok(oversized) =
    session.prepare(config.with_limits(settings, limits), lookup_request())
  let assert Ok(duplicate) = session.prepare(settings, lookup_request())
  let assert Ok(unnamed) = session.prepare(settings, lookup_request())

  let assert Error(session.RunFailure(
    types.ResourceLimitExceeded("argument_bytes_per_call_limit", 16, _),
    _,
  )) = session.run(oversized)
  let assert Error(session.RunFailure(types.ProtocolError(_), _)) =
    session.run(duplicate)
  let assert Error(session.RunFailure(types.ProtocolError(reason), _)) =
    session.run(unnamed)
  string.contains(reason, "invalid tool name") |> should.be_true
}

// Built-in reducers decode calls; the runtime alone decides admission.

fn sse(name: String, data: String) -> String {
  "event: " <> name <> "\ndata: " <> data <> "\n\n"
}

fn openai_body(calls: List(testing.ScriptedCall)) -> String {
  let items =
    list.index_map(calls, fn(call, index) {
      let at = "\"output_index\":" <> int.to_string(index)
      let item = "item_" <> int.to_string(index)
      sse(
        "response.output_item.added",
        "{"
          <> at
          <> ",\"item\":{\"id\":\""
          <> item
          <> "\",\"type\":\"function_call\",\"call_id\":\""
          <> call.id
          <> "\",\"name\":\""
          <> call.name
          <> "\"}}",
      )
      <> sse(
        "response.function_call_arguments.delta",
        "{"
          <> at
          <> ",\"item_id\":\""
          <> item
          <> "\",\"delta\":"
          <> json.to_string(json.string(call.arguments_json))
          <> "}",
      )
      <> sse(
        "response.output_item.done",
        "{" <> at <> ",\"item\":{\"id\":\"" <> item <> "\"}}",
      )
    })
  string.concat(items)
  <> sse(
    "response.completed",
    "{\"response\":{\"id\":\"resp_1\",\"status\":\"completed\"}}",
  )
}

fn anthropic_body(calls: List(testing.ScriptedCall)) -> String {
  let blocks =
    list.index_map(calls, fn(call, index) {
      let at = "\"index\":" <> int.to_string(index)
      sse(
        "content_block_start",
        "{\"type\":\"content_block_start\","
          <> at
          <> ",\"content_block\":{\"type\":\"tool_use\",\"id\":\""
          <> call.id
          <> "\",\"name\":\""
          <> call.name
          <> "\"}}",
      )
      <> sse(
        "content_block_delta",
        "{\"type\":\"content_block_delta\","
          <> at
          <> ",\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":"
          <> json.to_string(json.string(call.arguments_json))
          <> "}}",
      )
      <> sse(
        "content_block_stop",
        "{\"type\":\"content_block_stop\"," <> at <> "}",
      )
    })
  sse(
    "message_start",
    "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"m\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}",
  )
  <> string.concat(blocks)
  <> sse(
    "message_delta",
    "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":2}}",
  )
  <> sse("message_stop", "{\"type\":\"message_stop\"}")
}

fn google_body(calls: List(testing.ScriptedCall)) -> String {
  let parts =
    list.map(calls, fn(call) {
      "{\"functionCall\":{\"name\":\""
      <> call.name
      <> "\",\"id\":\""
      <> call.id
      <> "\",\"args\":"
      <> call.arguments_json
      <> "}}"
    })
  "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":["
  <> string.join(parts, ",")
  <> "]},\"finishReason\":\"STOP\"}]}\n\n"
}

fn built_in_settings() -> List(#(String, config.Config, String)) {
  let assert Ok(key) = types.api_key("sk-scripted")
  [
    #("openai", config.openai(openai.options(key)), openai_body(mixed_calls())),
    #(
      "anthropic",
      config.anthropic(anthropic.options(key)),
      anthropic_body(mixed_calls()),
    ),
    #("google", config.google(google.options(key)), google_body(mixed_calls())),
  ]
}

pub fn built_in_providers_report_per_call_issues_test() {
  list.each(built_in_settings(), fn(entry) {
    let #(provider_name, settings, body) = entry
    let script = testing.start([testing.Events([body])])
    let assert Ok(prepared) =
      session.prepare(
        settings |> testing.with_script(script) |> report,
        lookup_request(),
      )
    case session.run(prepared) {
      Ok(session.RunToolCalls(_, calls, continuation, _)) -> {
        list.map(calls, fn(call) { types.call_id_to_string(call.id) })
        |> should.equal(["call_ok", "call_unknown", "call_bad"])
        assert_mixed_issues(session.tool_call_issues(continuation))
      }
      other -> panic as { provider_name <> ": " <> string.inspect(other) }
    }
  })
}

pub fn built_in_providers_reject_invalid_calls_by_default_test() {
  list.each(built_in_settings(), fn(entry) {
    let #(provider_name, settings, body) = entry
    let script = testing.start([testing.Events([body])])
    let assert Ok(prepared) =
      session.prepare(settings |> testing.with_script(script), lookup_request())
    case session.run(prepared) {
      Error(session.RunFailure(types.ProtocolError(_), _)) -> Nil
      other -> panic as { provider_name <> ": " <> string.inspect(other) }
    }
  })
}

pub fn invalid_json_arguments_follow_the_selected_checks_test() {
  let assert Ok(key) = types.api_key("sk-scripted")
  let calls = [testing.ScriptedCall("call_1", "lookup", "{not valid")]
  let bodies = [
    #(config.openai(openai.options(key)), openai_body(calls)),
    #(config.anthropic(anthropic.options(key)), anthropic_body(calls)),
  ]
  list.each(bodies, fn(entry) {
    let #(settings, body) = entry
    let script = testing.start([testing.Events([body]), testing.Events([body])])
    let strict = settings |> testing.with_script(script)
    let assert Ok(rejected) = session.prepare(strict, lookup_request())
    let assert Ok(reported) = session.prepare(report(strict), lookup_request())

    let assert Error(session.RunFailure(types.ProtocolError(reason), _)) =
      session.run(rejected)
    reason |> should.equal("Invalid JSON in tool call arguments")
    let assert Ok(session.RunToolCalls(_, [_], continuation, _)) =
      session.run(reported)
    session.tool_call_issues(continuation)
    |> should.equal([
      types.InvalidArguments(
        call_id("call_1"),
        "Invalid JSON in tool call arguments",
      ),
    ])
  })
}

fn terminal(stream: session.Stream) -> session.Terminal {
  case session.next(stream) {
    Ok(session.NextProgress(_)) -> terminal(stream)
    Ok(session.StreamTerminal(value)) -> value
    Error(session.StreamReadError(types.ReadTimeout)) -> terminal(stream)
    Error(_) -> panic as "stream read failed"
  }
}
