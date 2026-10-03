//// Assistant turn replay: a caller keeps the returned turn, provider data
//// included, and replays it in a fresh request.

import conversation_fixture
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import http_test_helpers
import llm_wire
import llm_wire/error
import llm_wire/google
import llm_wire/limit
import llm_wire/message
import llm_wire/provider
import llm_wire/testing
import tool_fixtures

fn calc_request(model: String) -> llm_wire.Request(String) {
  llm_wire.request(model, [llm_wire.user("calculate")])
  |> llm_wire.with_tools([tool_fixtures.int_field_tool("calc", "x")])
}

pub fn caller_can_reuse_a_complete_signed_turn_in_a_fresh_request_test() {
  let settings = google.new("first-key") |> google.config
  let request = calc_request("turn-model")
  let reply =
    testing.Events([
      "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[{\"text\":\"thinking\",\"thoughtSignature\":\"text-sig\",\"opaque\":true},{\"functionCall\":{\"name\":\"calc\",\"id\":\"call_1\",\"args\":{\"x\":7}},\"thoughtSignature\":\"call-sig\"}]}}]}\n\n",
    ])
  let assert Ok(prepared) = llm_wire.prepare(settings, request)
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
    http_test_helpers.run_reply(prepared, reply)
  let assert [first_call] = turn.calls
  turn.text |> should.equal("thinking")
  first_call.provider_state |> should.equal(Some("call-sig"))
  let request =
    llm_wire.append(request, [
      message.Assistant(turn),
      llm_wire.tool_result(first_call, "14"),
    ])
  let assert Ok(next) =
    llm_wire.prepare(google.new("rotated-key") |> google.config, request)
  let body = llm_wire.request_json(next)
  string.contains(body, "text-sig") |> should.be_true
  string.contains(body, "call-sig") |> should.be_true
  string.contains(body, "\"opaque\":true") |> should.be_true
  string.contains(body, "\"output\":\"14\"") |> should.be_true
}

pub fn modified_or_missing_provider_data_is_rejected_before_another_request_test() {
  let configured = google.new("turn-validation") |> google.config
  let source = calc_request("turn-model")
  let reply =
    testing.Events([
      "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[{\"text\":\"thinking\",\"thoughtSignature\":\"text-sig\"},{\"functionCall\":{\"name\":\"calc\",\"id\":\"call_1\",\"args\":{\"x\":7}}}]}}]}\n\n",
    ])
  let assert Ok(prepared) = llm_wire.prepare(configured, source)
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
    http_test_helpers.run_reply(prepared, reply)
  let assert [first_call] = turn.calls
  let assert Some(data) = turn.provider_data
  let prepare_with = fn(changed: message.AssistantTurn) {
    llm_wire.prepare(
      configured,
      llm_wire.append(source, [
        message.Assistant(changed),
        message.ToolResult(first_call.id, "14"),
      ]),
    )
  }
  // The refusals are typed now: a turn from another provider, or provider
  // data that is missing, malformed or disagrees with the turn.
  prepare_with(message.AssistantTurn(..turn, provider: Some(message.OpenAI)))
  |> should.equal(Error(error.InvalidRequest(error.TurnFromOtherProvider)))
  let changed = [
    message.AssistantTurn(..turn, provider_data: None),
    message.AssistantTurn(..turn, provider_data: Some("[]")),
    message.AssistantTurn(..turn, provider_data: Some("{}")),
    message.AssistantTurn(..turn, text: "changed"),
    message.AssistantTurn(..turn, calls: [
      message.ToolCall(..first_call, arguments_json: "{\"x\":9}"),
    ]),
    message.AssistantTurn(
      ..turn,
      provider_data: Some(string.replace(data, "call_1", "other_id")),
    ),
  ]
  list.each(changed, fn(changed_turn) {
    let assert Error(error.InvalidRequest(error.InvalidProviderData(_))) =
      prepare_with(changed_turn)
  })
}

pub fn signed_history_and_repeated_ids_stay_with_their_caller_owned_round_test() {
  let settings = google.new("history-key") |> google.config
  let source =
    llm_wire.request("turn-model", [llm_wire.user("calculate")])
    |> llm_wire.with_tools([
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
  let assert Ok(first) = llm_wire.prepare(settings, source)
  let assert Ok(llm_wire.NeedsTools(turn: one, ..)) =
    http_test_helpers.run_reply(first, first_reply)
  let assert [first_call] = one.calls
  let second_source =
    conversation_fixture.append_results(source, one, [
      #(first_call.id, "first result"),
    ])
  let assert Ok(second) = llm_wire.prepare(settings, second_source)
  let assert Ok(llm_wire.NeedsTools(turn: two, ..)) =
    http_test_helpers.run_reply(second, second_reply)
  let assert [second_call] = two.calls
  let third_source =
    conversation_fixture.append_results(second_source, two, [
      #(second_call.id, "second result"),
    ])
  // A fresh configuration knows nothing about the preceding requests.
  let assert Ok(third) =
    llm_wire.prepare(google.new("history-key") |> google.config, third_source)
  let assert Ok([_, first_turn, first_result, second_turn, second_result]) =
    json.parse(
      llm_wire.request_json(third),
      decode.field("contents", decode.list(decode.dynamic), decode.success),
    )
  let assert Ok([text, first_part]) =
    decode.run(
      first_turn,
      decode.field("parts", decode.list(decode.dynamic), decode.success),
    )
  decode.run(
    text,
    decode.field("thoughtSignature", decode.string, decode.success),
  )
  |> should.equal(Ok("text-first"))
  decode.run(first_part, decode.at(["functionCall", "name"], decode.string))
  |> should.equal(Ok("calc"))
  let assert Ok([_, second_part]) =
    decode.run(
      second_turn,
      decode.field("parts", decode.list(decode.dynamic), decode.success),
    )
  decode.run(second_part, decode.at(["functionCall", "name"], decode.string))
  |> should.equal(Ok("lookup"))
  decode.run(second_part, decode.at(["functionCall", "args", "x"], decode.int))
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

// --- a custom adapter that owns its replay data --------------------------------

type State {
  State(text: String, calls: List(message.ToolCall), done: Bool)
}

/// A custom adapter, ported from the former `external_provider` fixture.
/// Its turns carry their text and calls as provider data, and its encoder
/// replays that data after checking it against the turn.
fn replaying_adapter(identity: message.Provider) -> llm_wire.Config {
  provider.new(identity, "https://custom.example/v1", encode, fn() {
    provider.reducer(State("", [], False), step, terminal)
  })
  |> provider.with_headers(fn() { [#("X-Fixture", "fourth")] })
  |> provider.config
}

fn encode(
  request: provider.Request,
  _tools: List(provider.ProjectedTool),
  _format: Option(provider.OutputFormat),
) -> Result(provider.Encoded, error.PrepareError) {
  use messages <- result.try(list.try_map(request.messages, encode_message))
  Ok(provider.encoded(
    "/events",
    json.to_string(
      json.object([
        #("model", json.string(request.model)),
        #("messages", json.preprocessed_array(messages)),
      ]),
    ),
  ))
}

fn encode_message(
  msg: message.Message,
) -> Result(json.Json, error.PrepareError) {
  case msg {
    message.Assistant(turn) ->
      case turn.provider_data {
        None -> Ok(assistant_calls(turn.text, turn.calls))
        Some(saved) -> {
          use #(text, call_ids) <- result.try(restore(saved))
          case
            text == turn.text
            && call_ids == list.map(turn.calls, fn(c) { c.id })
          {
            False ->
              Error(
                error.InvalidRequest(error.InvalidProviderData(
                  "fixture data differs from its turn",
                )),
              )
            True ->
              Ok(
                json.object([
                  #("role", json.string("assistant")),
                  #("replay_text", json.string(text)),
                  #("replay_call_ids", json.array(call_ids, json.string)),
                  #("turn", assistant_calls(turn.text, turn.calls)),
                ]),
              )
          }
        }
      }
    message.ToolResult(id, content) ->
      Ok(
        json.object([
          #("role", json.string("tool")),
          #("call_id", json.string(id)),
          #("content", json.string(content)),
        ]),
      )
    message.User(text) ->
      Ok(
        json.object([
          #("role", json.string("user")),
          #("text", json.string(text)),
        ]),
      )
    _ -> Ok(json.object([#("role", json.string("other"))]))
  }
}

fn assistant_calls(text: String, calls: List(message.ToolCall)) -> json.Json {
  json.object([
    #("role", json.string("assistant")),
    #("text", json.string(text)),
    #(
      "calls",
      json.array(calls, fn(c) {
        json.object([
          #("id", json.string(c.id)),
          #("name", json.string(c.name)),
          #("arguments", json.string(c.arguments_json)),
        ])
      }),
    ),
  ])
}

fn restore(
  saved: String,
) -> Result(#(String, List(String)), error.PrepareError) {
  let decoder = {
    use text <- decode.field("text", decode.string)
    use ids <- decode.field(
      "calls",
      decode.list(decode.field("id", decode.string, decode.success)),
    )
    decode.success(#(text, ids))
  }
  json.parse(saved, decoder)
  |> result.replace_error(
    error.InvalidRequest(error.InvalidProviderData("invalid fixture replay")),
  )
}

fn step(
  state: State,
  event: provider.Event,
) -> Result(#(State, List(message.Progress)), error.Error) {
  case event.event {
    Some("text") ->
      Ok(
        #(State(..state, text: state.text <> event.data), [
          message.TextDelta("0", event.data),
        ]),
      )
    Some("tool") ->
      case string.split(event.data, "|") {
        [id, name, arguments] ->
          Ok(
            #(
              State(
                ..state,
                calls: list.append(state.calls, [
                  message.tool_call(id, name, arguments),
                ]),
              ),
              [],
            ),
          )
        _ -> Error(error.Protocol("Malformed fixture tool event"))
      }
    Some("done") -> Ok(#(State(..state, done: True), []))
    _ -> Ok(#(state, []))
  }
}

fn terminal(state: State) -> Option(provider.Terminal) {
  case state.done, state.calls {
    False, _ -> None
    True, [] -> Some(provider.text(state.text, None))
    True, calls ->
      Some(provider.tool_calls(
        state.text,
        calls,
        Some("response-fourth"),
        Some(json.to_string(assistant_calls(state.text, calls))),
        None,
      ))
  }
}

fn custom_reply() -> testing.Reply {
  testing.Events([
    "event: text\ndata: custom turn\n\nevent: tool\ndata: call_1|calc|{\"x\":7}\n\nevent: done\ndata: {}\n\n",
  ])
}

pub fn custom_adapter_interprets_its_own_data_even_with_google_identity_test() {
  let settings = replaying_adapter(message.Google)
  let source = calc_request("custom-model")
  let assert Ok(prepared) = llm_wire.prepare(settings, source)
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
    http_test_helpers.run_reply(prepared, custom_reply())
  turn.provider |> should.equal(Some(message.Google))
  let assert [first_call] = turn.calls
  let assert Ok(next) =
    llm_wire.prepare(
      settings,
      conversation_fixture.append_results(source, turn, [
        #(first_call.id, "14"),
      ]),
    )
  let assert Ok([_, assistant, _]) =
    json.parse(
      llm_wire.request_json(next),
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
  let settings = replaying_adapter(message.Custom("scripted-fourth"))
  let source = calc_request("custom-model")
  let assert Ok(first) = llm_wire.prepare(settings, source)
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
    http_test_helpers.run_reply(first, custom_reply())
  let assert Some(data) = turn.provider_data
  let bounded =
    llm_wire.with_limit(
      settings,
      limit.ProviderMetadataBytes,
      string.byte_size(data),
    )
  let assert Ok(second) = llm_wire.prepare(bounded, source)
  let assert Error(failure) =
    http_test_helpers.run_reply(second, custom_reply())
  let assert error.LimitExceeded(limit.ProviderMetadataBytes, _, _) =
    failure.error
  let assert [first_call] = turn.calls
  let next_request =
    conversation_fixture.append_results(source, turn, [#(first_call.id, "14")])
  let assert Error(error.RequestTooLarge(limit.ProviderMetadataBytes, _, _)) =
    llm_wire.prepare(bounded, next_request)
}

pub fn every_assistant_message_form_enforces_the_metadata_budget_test() {
  let settings =
    google.new("metadata-key")
    |> google.config
    |> llm_wire.with_limit(limit.ProviderMetadataBytes, 16)
  let signed =
    message.ToolCall(
      ..message.tool_call("call_1", "calc", "{}"),
      provider_state: Some(string.repeat("s", 32)),
    )
  // `AssistantToolCalls` and `AssistantToolCallsWithText` are both an
  // application-written `message.Assistant` turn now.
  list.each(["", "thinking"], fn(text) {
    let request =
      llm_wire.request("turn-model", [
        llm_wire.user("calculate"),
        message.Assistant(message.AssistantTurn(
          provider: None,
          text:,
          calls: [signed],
          response_id: None,
          provider_data: None,
        )),
        message.ToolResult("call_1", "14"),
      ])
    let assert Error(error.RequestTooLarge(limit.ProviderMetadataBytes, 16, _)) =
      llm_wire.prepare(settings, request)
  })
}
