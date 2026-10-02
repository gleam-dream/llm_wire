// This module deliberately imports only public package modules. The boundary
// gate also compiles it as source in a separate consumer package.
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm_wire/provider
import llm_wire/types

type Turn {
  Turn(text: String, calls: List(types.ToolCall))
}

type State {
  State(
    text: String,
    calls: List(types.ToolCall),
    done: Bool,
    limited: Bool,
    refusal: Option(String),
    failure: Option(types.WireError),
  )
}

pub fn adapter(endpoint: types.Endpoint) -> provider.Adapter {
  configured_adapter(endpoint, False, types.Custom("scripted-fourth"))
}

pub fn failing_adapter(endpoint: types.Endpoint) -> provider.Adapter {
  configured_adapter(endpoint, True, types.Custom("scripted-fourth"))
}

pub fn google_identified_adapter(endpoint: types.Endpoint) -> provider.Adapter {
  configured_adapter(endpoint, False, types.Google)
}

fn configured_adapter(
  endpoint: types.Endpoint,
  fail_reducer: Bool,
  identity: types.Provider,
) -> provider.Adapter {
  provider.adapter(
    provider.Spec(
      identity: identity,
      endpoint: endpoint,
      headers: fn() { [#("X-Fixture", "fourth")] },
      encode: fn(request, tools, format) {
        encode_request(request, tools, format)
      },
      project_tool_schema: provider.blueprint_schema,
      project_output_schema: provider.blueprint_schema,
      new_reducer: fn(_limits, _tools) {
        case fail_reducer {
          True ->
            Error(types.ConfigurationError(
              "fixture reducer failed before transport",
            ))
          False ->
            Ok(
              provider.reducer(
                State("", [], False, False, None, None),
                step,
                terminal,
                fn(_state, fallback) {
                  types.RetryEvidence(fallback, False, False)
                },
              ),
            )
        }
      },
    ),
  )
}

fn encode_request(
  request: types.Request,
  tools: List(provider.ProjectedTool),
  format: Option(provider.OutputFormat),
) -> Result(provider.EncodedRequest, types.WireError) {
  use messages <- result.try(list.try_map(request.messages, encode_message))
  let projected =
    list.map(tools, fn(tool) {
      let provider.ProjectedTool(name, description, schema_json) = tool
      json.object([
        #("name", json.string(types.tool_name_to_string(name))),
        #("description", json.string(description)),
        #("input_schema", schema_json),
      ])
    })
  let format_fields = case format {
    None -> []
    Some(provider.OutputFormat(name, schema_json)) -> [
      #("output_name", json.string(name)),
      #("output_schema", schema_json),
    ]
  }
  Ok(provider.EncodedRequest(
    "/events",
    json.to_string(
      json.object(list.append(
        [
          #("model", json.string(types.model_id_to_string(request.model))),
          #("messages", json.array(messages, fn(value) { value })),
          #("tools", json.array(projected, fn(value) { value })),
        ],
        format_fields,
      )),
    ),
  ))
}

fn encode_message(
  message: types.Message,
) -> Result(json.Json, types.WireError) {
  case message {
    types.SystemMessage(text) -> Ok(message_json("system", text))
    types.UserMessage(text) -> Ok(message_json("user", text))
    types.UserContent(_) -> Ok(message_json("user", "[content]"))
    types.AssistantMessage(text) -> Ok(message_json("assistant", text))
    types.AssistantContent(_) -> Ok(message_json("assistant", "[content]"))
    types.AssistantToolCalls(calls) -> Ok(assistant_calls("", calls))
    types.AssistantToolCallsWithText(text, calls) ->
      Ok(assistant_calls(text, calls))
    types.AssistantTurnMessage(turn) -> {
      case turn.provider_data {
        None -> Ok(assistant_calls(turn.text, turn.calls))
        Some(saved) -> {
          use retained <- result.try(restore_state(saved))
          case retained.text == turn.text && retained.calls == turn.calls {
            False ->
              Error(types.PreparationError(
                "Fixture provider data differs from its assistant turn",
              ))
            True ->
              Ok(
                json.object([
                  #("role", json.string("assistant")),
                  #("text", json.string(turn.text)),
                  #("replay_text", json.string(retained.text)),
                  #(
                    "replay_call_ids",
                    json.array(retained.calls, fn(call) {
                      json.string(types.call_id_to_string(call.id))
                    }),
                  ),
                  #("turn", assistant_calls(turn.text, turn.calls)),
                ]),
              )
          }
        }
      }
    }
    types.ToolResultMessage(id, content) ->
      Ok(
        json.object([
          #("role", json.string("tool")),
          #("call_id", json.string(types.call_id_to_string(id))),
          #("content", json.string(content)),
        ]),
      )
  }
}

fn message_json(role: String, text: String) -> json.Json {
  json.object([#("role", json.string(role)), #("text", json.string(text))])
}

fn assistant_calls(text: String, calls: List(types.ToolCall)) -> json.Json {
  json.object([
    #("role", json.string("assistant")),
    #("text", json.string(text)),
    #(
      "calls",
      json.array(calls, fn(call) {
        json.object([
          #("id", json.string(types.call_id_to_string(call.id))),
          #("name", json.string(types.tool_name_to_string(call.name))),
          #("arguments", json.string(call.arguments_json)),
        ])
      }),
    ),
  ])
}

fn step(
  state: State,
  event: provider.Event,
) -> Result(#(State, List(types.StreamProgress)), types.WireError) {
  case event.event {
    Some("text") -> {
      let next = State(..state, text: state.text <> event.data)
      Ok(#(next, [types.TextDelta("0", event.data)]))
    }
    Some("tool") -> {
      use call <- result.try(parse_call(event.data))
      Ok(#(State(..state, calls: list.append(state.calls, [call])), []))
    }
    Some("done") -> Ok(#(State(..state, done: True), []))
    Some("oversized_done") ->
      Ok(
        #(State(..state, text: event.data, done: True), [
          types.TextDelta("0", event.data),
        ]),
      )
    Some("long_id") -> Ok(#(state, [types.TextDelta(event.data, "x")]))
    Some("batch_over_limit") ->
      Ok(
        #(state, [types.TextDelta("0", "ok"), types.TextDelta("0", event.data)]),
      )
    Some("metadata_tool") -> {
      let assert Ok(id) = types.call_id("call-1")
      let assert Ok(name) = types.tool_name("calc")
      let call = types.tool_call(id, name, "{\"x\":7}")
      Ok(
        #(
          State(
            ..state,
            calls: [types.ToolCall(..call, provider_state: Some(event.data))],
            done: True,
          ),
          [],
        ),
      )
    }
    Some("limited") -> Ok(#(State(..state, done: True, limited: True), []))
    Some("refusal") ->
      Ok(#(State(..state, done: True, refusal: Some(event.data)), []))
    Some("failure") ->
      Ok(
        #(
          State(
            ..state,
            done: True,
            failure: Some(types.ProviderError(Some("fixture"), event.data)),
          ),
          [],
        ),
      )
    Some("extension") ->
      Ok(#(state, [types.ProviderExtension("scripted-fourth", event.data)]))
    _ -> Ok(#(state, []))
  }
}

fn parse_call(raw: String) -> Result(types.ToolCall, types.WireError) {
  case string.split(raw, "|") {
    [raw_id, raw_name, arguments_json] -> {
      use id <- result.try(types.call_id(raw_id))
      use name <- result.try(
        types.tool_name(raw_name)
        |> result.replace_error(types.ProtocolError(
          "Malformed fixture tool name",
        )),
      )
      Ok(types.tool_call(id, name, arguments_json))
    }
    _ -> Error(types.ProtocolError("Malformed fixture tool event"))
  }
}

fn terminal(state: State) -> Option(provider.Terminal) {
  case state.done, state.failure, state.refusal, state.limited, state.calls {
    False, _, _, _, _ -> None
    True, Some(error), _, _, _ ->
      Some(provider.Failure(
        error,
        types.RetryEvidence(types.NoRequestSent, False, False),
      ))
    True, None, Some(reason), _, _ -> Some(provider.Refusal(reason, None))
    True, None, None, True, _ ->
      Some(provider.OutputLimited(state.text, state.calls, None))
    True, None, None, False, [] -> Some(provider.Text(state.text, None))
    True, None, None, False, calls -> {
      Some(provider.ToolCalls(
        state.text,
        calls,
        Some("response-fourth"),
        Some(assistant_calls(state.text, calls) |> json.to_string),
        None,
      ))
    }
  }
}

fn restore_state(saved: String) -> Result(Turn, types.WireError) {
  let call_decoder = {
    use id <- decode.field("id", decode.string)
    use name <- decode.field("name", decode.string)
    use arguments <- decode.field("arguments", decode.string)
    decode.success(#(id, name, arguments))
  }
  let decoder = {
    use text <- decode.field("text", decode.string)
    use calls <- decode.field("calls", decode.list(call_decoder))
    decode.success(#(text, calls))
  }
  use state <- result.try(
    json.parse(saved, decoder)
    |> result.replace_error(types.PreparationError("Invalid fixture replay")),
  )
  let #(text, raw_calls) = state
  use calls <- result.try(
    list.try_map(raw_calls, fn(raw) {
      let #(id, name, arguments) = raw
      use id <- result.try(types.call_id(id))
      use name <- result.try(
        types.tool_name(name)
        |> result.replace_error(types.PreparationError("Invalid fixture tool")),
      )
      Ok(types.tool_call(id, name, arguments))
    }),
  )
  Ok(Turn(text, calls))
}
