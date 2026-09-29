//// The public test provider through the ordinary session path. These tests
//// import only public modules; no socket is opened.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import llm_wire/config
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/testing
import llm_wire/types
import tool_fixtures

fn request(messages: List(types.Message)) -> types.Request {
  let assert Ok(model) = types.model_id("scripted-model")
  types.new_request(model, messages)
}

fn lookup_request() -> types.Request {
  request([types.UserMessage("Find gleam")])
  |> types.with_tools([tool_fixtures.string_field_tool("lookup", "query")])
}

fn read_all(
  stream: session.Stream,
  seen: List(types.StreamProgress),
) -> #(List(types.StreamProgress), session.Terminal) {
  case session.next(stream) {
    Ok(session.NextProgress(progress)) -> read_all(stream, [progress, ..seen])
    Ok(session.StreamTerminal(terminal)) -> #(list.reverse(seen), terminal)
    Error(session.StreamReadError(types.ReadTimeout)) -> read_all(stream, seen)
    Error(_) -> panic as "stream read failed"
  }
}

pub fn scripted_text_runs_through_the_session_test() {
  let script = testing.start([testing.text("hello")])
  let assert Ok(prepared) =
    session.prepare(testing.config(script), request([types.UserMessage("Hi")]))

  session.run(prepared) |> should.equal(Ok(session.RunText("hello", None)))

  let assert [recorded] = testing.requests(script)
  recorded.request.messages |> should.equal([types.UserMessage("Hi")])
  testing.remaining(script) |> should.equal(0)
}

pub fn scripted_usage_is_reported_test() {
  let usage = types.Usage(input_tokens: 3, output_tokens: 2, total_tokens: 5)
  let script = testing.start([testing.text("hi") |> testing.with_usage(usage)])
  let assert Ok(prepared) =
    session.prepare(testing.config(script), request([types.UserMessage("Hi")]))

  session.run(prepared) |> should.equal(Ok(session.RunText("hi", Some(usage))))
}

pub fn scripted_stream_reports_progress_before_the_terminal_test() {
  let script = testing.start([testing.text("streamed")])
  let assert Ok(prepared) =
    session.prepare(testing.config(script), request([types.UserMessage("Hi")]))
  let assert Ok(stream) = session.stream(prepared)

  let #(progress, terminal) = read_all(stream, [])
  progress |> should.equal([types.TextDelta("0", "streamed")])
  terminal |> should.equal(session.Finished(session.RunText("streamed", None)))
}

pub fn scripted_tool_round_continues_with_exact_results_test() {
  let script =
    testing.start([
      testing.tool_calls("Looking.", [
        testing.ScriptedCall("call_1", "lookup", "{\"query\":\"gleam\"}"),
      ]),
      testing.text("Found it."),
    ])
  let assert Ok(prepared) =
    session.prepare(testing.config(script), lookup_request())
  let assert Ok(session.RunToolCalls(turn, None)) = session.run(prepared)
  turn.text |> should.equal("Looking.")
  let assert [call] = turn.calls
  types.call_id_to_string(call.id) |> should.equal("call_1")
  types.tool_name_to_string(call.name) |> should.equal("lookup")
  call.arguments_json |> should.equal("{\"query\":\"gleam\"}")

  // Coverage is checked before the second scripted reply is consumed.
  let source = lookup_request()
  let pending =
    types.Request(
      ..source,
      messages: list.append(source.messages, [types.AssistantTurnMessage(turn)]),
    )
  session.prepare(testing.config(script), pending) |> should.be_error
  let ready =
    types.Request(
      ..pending,
      messages: list.append(pending.messages, [
        types.ToolResultMessage(call.id, "gleam.run"),
      ]),
    )
  let assert Ok(next) = session.prepare(testing.config(script), ready)
  session.run(next) |> should.equal(Ok(session.RunText("Found it.", None)))

  let assert [_, second] = testing.requests(script)
  second.request.messages
  |> should.equal([
    types.UserMessage("Find gleam"),
    types.AssistantTurnMessage(turn),
    types.ToolResultMessage(call.id, "gleam.run"),
  ])
}

pub fn scripted_structured_output_is_validated_and_decoded_test() {
  let script = testing.start([testing.text("{\"answer\":42}")])
  let assert Ok(prepared) =
    session.prepare_structured(
      testing.config(script),
      request([types.UserMessage("Answer")]),
      "answer",
      codec.field("answer", codec.int()),
    )

  let assert Ok(session.StructuredValue(42, "{\"answer\":42}", None)) =
    session.run_structured(prepared)
}

pub fn scripted_refusal_and_output_limit_are_distinct_outcomes_test() {
  let script =
    testing.start([testing.refusal("no"), testing.output_limited("partial")])
  let settings = testing.config(script)
  let assert Ok(first) =
    session.prepare(settings, request([types.UserMessage("One")]))
  let assert Ok(second) =
    session.prepare(settings, request([types.UserMessage("Two")]))

  session.run(first) |> should.equal(Ok(session.RunRefusal("no", None)))
  session.run(second)
  |> should.equal(Ok(session.RunOutputLimited("partial", [], None)))
}

pub fn scripted_status_fails_after_the_request_was_sent_test() {
  let script = testing.start([testing.Status(429, "{\"error\":\"slow down\"}")])
  let assert Ok(prepared) =
    session.prepare(testing.config(script), request([types.UserMessage("Hi")]))

  let assert Error(session.RunFailure(
    types.HttpStatusError(429, "{\"error\":\"slow down\"}", None),
    retry,
  )) = session.run(prepared)
  retry.classification |> should.equal(types.RequestMayHaveReachedProvider)
  retry.response_bytes_observed |> should.be_true
}

pub fn scripted_interruption_is_a_transport_failure_test() {
  let script = testing.start([testing.Interrupted([])])
  let assert Ok(prepared) =
    session.prepare(testing.config(script), request([types.UserMessage("Hi")]))

  let assert Error(session.RunFailure(types.TransportError(_), _)) =
    session.run(prepared)
}

pub fn exhausted_script_fails_without_a_reply_test() {
  let script = testing.start([])
  let assert Ok(prepared) =
    session.prepare(testing.config(script), request([types.UserMessage("Hi")]))

  let assert Error(session.RunFailure(types.ConfigurationError(_), _)) =
    session.run(prepared)
  // The attempted request is still recorded for the test to inspect.
  list.length(testing.requests(script)) |> should.equal(1)
}

pub fn raw_events_drive_a_built_in_provider_without_a_socket_test() {
  let assert Ok(key) = types.api_key("sk-scripted")
  let body =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n"
    <> "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"item\",\"delta\":\"ok\"}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}\n\n"
  // Split inside an event: the SSE framer must reassemble it.
  let script =
    testing.start([
      testing.Events([string.slice(body, 0, 40), string.drop_start(body, 40)]),
    ])
  let settings =
    config.openai(openai.options(key)) |> testing.with_script(script)
  let assert Ok(prepared) =
    session.prepare(settings, request([types.UserMessage("Hi")]))

  session.run(prepared) |> should.equal(Ok(session.RunText("ok", None)))
  let assert [recorded] = testing.requests(script)
  recorded.path |> should.equal("/v1/responses")
  recorded.body |> should.equal(session.prepared_request_json(prepared))
}
