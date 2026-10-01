import conversation_fixture
import external_provider
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import http_test_helpers
import llm_wire/config
import llm_wire/provider/google
import llm_wire/session
import llm_wire/testing
import llm_wire/types
import tool_fixtures

pub fn caller_can_reuse_a_complete_signed_turn_in_a_fresh_request_test() {
  let assert Ok(key) = types.api_key("first-key")
  let settings = config.google(google.options(key))
  let assert Ok(model) = types.model_id("turn-model")
  let request =
    types.new_request(model, [types.UserMessage("calculate")])
    |> types.with_tools([tool_fixtures.int_field_tool("calc", "x")])
  let reply =
    testing.Events([
      "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[{\"text\":\"thinking\",\"thoughtSignature\":\"text-sig\",\"opaque\":true},{\"functionCall\":{\"name\":\"calc\",\"id\":\"call_1\",\"args\":{\"x\":7}},\"thoughtSignature\":\"call-sig\"}]}}]}\n\n",
    ])
  let script = [reply]
  let assert Ok(prepared) = session.prepare(settings, request)
  let assert Ok(session.RunToolCalls(turn, _)) =
    http_test_helpers.run_reply(
      prepared,
      list.first(list.drop(script, 0)) |> should.be_ok,
    )
  let assert [call] = turn.calls
  turn.text |> should.equal("thinking")
  call.provider_state |> should.equal(Some("call-sig"))
  let request =
    types.Request(
      ..request,
      messages: list.append(request.messages, [
        types.AssistantTurnMessage(turn),
        types.ToolResultMessage(call.id, "14"),
      ]),
    )
  let assert Ok(key) = types.api_key("rotated-key")
  let assert Ok(next) =
    session.prepare(config.google(google.options(key)), request)
  let body = session.prepared_request_json(next)
  string.contains(body, "text-sig") |> should.be_true
  string.contains(body, "call-sig") |> should.be_true
  string.contains(body, "\"opaque\":true") |> should.be_true
  string.contains(body, "\"output\":\"14\"") |> should.be_true
}

pub fn modified_or_missing_provider_data_is_rejected_before_another_request_test() {
  let assert Ok(key) = types.api_key("turn-validation")
  let settings = config.google(google.options(key))
  let assert Ok(model) = types.model_id("turn-model")
  let source =
    types.new_request(model, [types.UserMessage("calculate")])
    |> types.with_tools([tool_fixtures.int_field_tool("calc", "x")])
  let reply =
    testing.Events([
      "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[{\"text\":\"thinking\",\"thoughtSignature\":\"text-sig\"},{\"functionCall\":{\"name\":\"calc\",\"id\":\"call_1\",\"args\":{\"x\":7}}}]}}]}\n\n",
    ])
  let script = [reply, reply]
  let configured = settings
  let assert Ok(prepared) = session.prepare(configured, source)
  let assert Ok(session.RunToolCalls(turn, _)) =
    http_test_helpers.run_reply(
      prepared,
      list.first(list.drop(script, 0)) |> should.be_ok,
    )
  let assert [call] = turn.calls
  let assert Some(data) = turn.provider_data
  let changed = [
    types.AssistantTurn(..turn, provider: types.OpenAI),
    types.AssistantTurn(..turn, provider_data: None),
    types.AssistantTurn(..turn, provider_data: Some("[]")),
    types.AssistantTurn(..turn, provider_data: Some("{}")),
    types.AssistantTurn(..turn, text: "changed"),
    types.AssistantTurn(..turn, calls: [
      types.ToolCall(..call, arguments_json: "{\"x\":9}"),
    ]),
    types.AssistantTurn(
      ..turn,
      provider_data: Some(string.replace(data, "call_1", "other_id")),
    ),
  ]
  list.each(changed, fn(turn) {
    let request =
      types.Request(
        ..source,
        messages: list.append(source.messages, [
          types.AssistantTurnMessage(turn),
          types.ToolResultMessage(call.id, "14"),
        ]),
      )
    session.prepare(configured, request) |> should.be_error
  })
}

pub fn signed_history_and_repeated_ids_stay_with_their_caller_owned_round_test() {
  let assert Ok(key) = types.api_key("history-key")
  let settings = config.google(google.options(key))
  let assert Ok(model) = types.model_id("turn-model")
  let source =
    types.new_request(model, [types.UserMessage("calculate")])
    |> types.with_tools([
      tool_fixtures.int_field_tool("calc", "x"),
      tool_fixtures.int_field_tool("lookup", "x"),
    ])
  let first_reply =
    testing.Events([
      "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[{\"text\":\"first thought\",\"thoughtSignature\":\"text-first\"},{\"functionCall\":{\"name\":\"calc\",\"id\":\"same-id\",\"args\":{\"x\":1}}}]}}]}\n\n",
    ])
  let second_reply =
    testing.Events([
      "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[{\"text\":\"second thought\"},{\"functionCall\":{\"name\":\"lookup\",\"id\":\"same-id\",\"args\":{\"x\":2}}}]}}]}\n\n",
    ])
  let script = [first_reply, second_reply]
  let configured = settings
  let assert Ok(first) = session.prepare(configured, source)
  let assert Ok(session.RunToolCalls(one, _)) =
    http_test_helpers.run_reply(
      first,
      list.first(list.drop(script, 0)) |> should.be_ok,
    )
  let assert [call] = one.calls
  let second_source =
    conversation_fixture.append_results(source, one, [
      types.ToolResult(call.id, "first result"),
    ])
  let assert Ok(second) = session.prepare(configured, second_source)
  let assert Ok(session.RunToolCalls(two, _)) =
    http_test_helpers.run_reply(
      second,
      list.first(list.drop(script, 1)) |> should.be_ok,
    )
  let assert [call] = two.calls
  let third_source =
    conversation_fixture.append_results(second_source, two, [
      types.ToolResult(call.id, "second result"),
    ])
  // A fresh configuration knows nothing about the preceding requests.
  let assert Ok(third) = session.prepare(settings, third_source)
  let assert Ok([_, first_turn, first_result, second_turn, second_result]) =
    json.parse(
      session.prepared_request_json(third),
      decode.field("contents", decode.list(decode.dynamic), decode.success),
    )
  let assert Ok([text, first_call]) =
    decode.run(
      first_turn,
      decode.field("parts", decode.list(decode.dynamic), decode.success),
    )
  decode.run(
    text,
    decode.field("thoughtSignature", decode.string, decode.success),
  )
  |> should.equal(Ok("text-first"))
  decode.run(first_call, decode.at(["functionCall", "name"], decode.string))
  |> should.equal(Ok("calc"))
  let assert Ok([_, second_call]) =
    decode.run(
      second_turn,
      decode.field("parts", decode.list(decode.dynamic), decode.success),
    )
  decode.run(second_call, decode.at(["functionCall", "name"], decode.string))
  |> should.equal(Ok("lookup"))
  decode.run(second_call, decode.at(["functionCall", "args", "x"], decode.int))
  |> should.equal(Ok(2))
  list.each(
    [
      #(first_result, "calc", "first result"),
      #(second_result, "lookup", "second result"),
    ],
    fn(pair) {
      let assert Ok([part]) =
        decode.run(
          pair.0,
          decode.field("parts", decode.list(decode.dynamic), decode.success),
        )
      decode.run(part, decode.at(["functionResponse", "name"], decode.string))
      |> should.equal(Ok(pair.1))
      decode.run(part, decode.at(["functionResponse", "id"], decode.string))
      |> should.equal(Ok("same-id"))
      decode.run(
        part,
        decode.at(["functionResponse", "response", "output"], decode.string),
      )
      |> should.equal(Ok(pair.2))
    },
  )
}

pub fn custom_adapter_interprets_its_own_data_even_with_google_identity_test() {
  let assert Ok(endpoint) = types.endpoint("https://custom.example/v1")
  let settings =
    config.from_provider(external_provider.google_identified_adapter(endpoint))
  let assert Ok(model) = types.model_id("custom-model")
  let source =
    types.new_request(model, [types.UserMessage("calculate")])
    |> types.with_tools([tool_fixtures.int_field_tool("calc", "x")])
  let script = [
    testing.Events([
      "event: text\ndata: custom turn\n\nevent: tool\ndata: call_1|calc|{\"x\":7}\n\nevent: done\ndata: {}\n\n",
    ]),
  ]
  let assert Ok(prepared) = session.prepare(settings, source)
  let assert Ok(session.RunToolCalls(turn, _)) =
    http_test_helpers.run_reply(
      prepared,
      list.first(list.drop(script, 0)) |> should.be_ok,
    )
  let assert [call] = turn.calls
  let assert Ok(next) =
    session.prepare(
      settings,
      conversation_fixture.append_results(source, turn, [
        types.ToolResult(call.id, "14"),
      ]),
    )
  let assert Ok([_, assistant, _]) =
    json.parse(
      session.prepared_request_json(next),
      decode.field("messages", decode.list(decode.dynamic), decode.success),
    )
  decode.run(
    assistant,
    decode.field("replay_text", decode.string, decode.success),
  )
  |> should.equal(Ok("custom turn"))
  decode.run(
    assistant,
    decode.field("replay_call_ids", decode.list(decode.string), decode.success),
  )
  |> should.equal(Ok(["call_1"]))
}

pub fn provider_data_and_normalized_metadata_share_one_byte_budget_test() {
  let assert Ok(endpoint) = types.endpoint("https://custom.example/v1")
  let settings = config.from_provider(external_provider.adapter(endpoint))
  let assert Ok(model) = types.model_id("custom-model")
  let source =
    types.new_request(model, [types.UserMessage("calculate")])
    |> types.with_tools([tool_fixtures.int_field_tool("calc", "x")])
  let reply =
    testing.Events([
      "event: text\ndata: custom turn\n\nevent: tool\ndata: call_1|calc|{\"x\":7}\n\nevent: done\ndata: {}\n\n",
    ])
  let script = [reply, reply]
  let assert Ok(first) = session.prepare(settings, source)
  let assert Ok(session.RunToolCalls(turn, _)) =
    http_test_helpers.run_reply(
      first,
      list.first(list.drop(script, 0)) |> should.be_ok,
    )
  let assert Some(data) = turn.provider_data
  let limits =
    types.Limits(
      ..types.default_limits(),
      provider_metadata_bytes_limit: string.byte_size(data),
    )
  let bounded = config.with_limits(settings, limits)
  let assert Ok(second) = session.prepare(bounded, source)
  let assert Error(session.RunFailure(
    types.ResourceLimitExceeded("provider_metadata_bytes_limit", _, _),
    _,
  )) =
    http_test_helpers.run_reply(
      second,
      list.first(list.drop(script, 1)) |> should.be_ok,
    )
  let assert [call] = turn.calls
  let next_request =
    conversation_fixture.append_results(source, turn, [
      types.ToolResult(call.id, "14"),
    ])
  let assert Error(types.ResourceLimitExceeded(
    "provider_metadata_bytes_limit",
    _,
    _,
  )) = session.prepare(bounded, next_request)
}

pub fn every_assistant_message_form_enforces_the_metadata_budget_test() {
  let assert Ok(key) = types.api_key("metadata-key")
  let limits =
    types.Limits(..types.default_limits(), provider_metadata_bytes_limit: 16)
  let settings =
    config.google(google.options(key)) |> config.with_limits(limits)
  let assert Ok(model) = types.model_id("turn-model")
  let assert Ok(id) = types.call_id("call_1")
  let assert Ok(name) = types.tool_name("calc")
  let call = types.ToolCall(id, name, "{}", None, Some(string.repeat("s", 32)))
  list.each(
    [
      types.AssistantToolCalls([call]),
      types.AssistantToolCallsWithText("thinking", [call]),
    ],
    fn(message) {
      let request =
        types.new_request(model, [
          types.UserMessage("calculate"),
          message,
          types.ToolResultMessage(id, "14"),
        ])
      let assert Error(types.ResourceLimitExceeded(
        "provider_metadata_bytes_limit",
        _,
        _,
      )) = session.prepare(settings, request)
    },
  )
}
