// This module deliberately imports only public package modules. The boundary
// gate also compiles it as source in a separate consumer package.
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm_wire/error
import llm_wire/message
import llm_wire/provider
import llm_wire/tool

type Turn {
  Turn(text: String, calls: List(message.ToolCall))
}

type State {
  State(
    text: String,
    calls: List(message.ToolCall),
    done: Bool,
    limited: Bool,
    refusal: Option(String),
    failure: Option(error.Error),
  )
}

/// The fixture adapter at `endpoint`, named `scripted-fourth`.
pub fn adapter(endpoint: String) -> provider.Adapter {
  configured_adapter(endpoint, message.Custom("scripted-fourth"))
}

/// The same adapter identified as Google: its data stays its own.
pub fn google_identified_adapter(endpoint: String) -> provider.Adapter {
  configured_adapter(endpoint, message.Google)
}

fn configured_adapter(
  endpoint: String,
  identity: message.Provider,
) -> provider.Adapter {
  provider.new(identity, endpoint, encode_request, fn() {
    provider.reducer(State("", [], False, False, None, None), step, terminal)
  })
  |> provider.with_headers(fn() { [#("X-Fixture", "fourth")] })
}

fn encode_request(
  request: provider.Request,
  tools: List(provider.ProjectedTool),
  format: Option(provider.OutputFormat),
) -> Result(provider.Encoded, error.PrepareError) {
  use messages <- result.try(list.try_map(request.messages, encode_message))
  let projected =
    list.map(tools, fn(projected: provider.ProjectedTool) {
      json.object([
        #("name", json.string(projected.name)),
        #("description", json.string(projected.description)),
        #("input_schema", projected.schema),
      ])
    })
  let format_fields = case format {
    None -> []
    Some(output) -> [
      #("output_name", json.string(output.name)),
      #("output_schema", output.schema),
    ]
  }
  Ok(provider.encoded(
    "/events",
    json.to_string(
      json.object(list.append(
        [
          #("model", json.string(request.model)),
          #("messages", json.array(messages, fn(value) { value })),
          #("tools", json.array(projected, fn(value) { value })),
        ],
        format_fields,
      )),
    ),
  ))
}

fn encode_message(
  entry: message.Message,
) -> Result(json.Json, error.PrepareError) {
  case entry {
    message.System(text) -> Ok(message_json("system", text))
    message.User(text) -> Ok(message_json("user", text))
    message.UserParts(_) -> Ok(message_json("user", "[content]"))
    message.AssistantParts(_) -> Ok(message_json("assistant", "[content]"))
    message.Assistant(turn) ->
      case turn.provider_data {
        None -> Ok(assistant_calls(turn.text, turn.calls))
        Some(saved) -> {
          use retained <- result.try(restore_state(saved))
          case retained.text == turn.text && retained.calls == turn.calls {
            False ->
              Error(
                error.InvalidRequest(error.InvalidProviderData(
                  "Fixture provider data differs from its assistant turn",
                )),
              )
            True ->
              Ok(
                json.object([
                  #("role", json.string("assistant")),
                  #("text", json.string(turn.text)),
                  #("replay_text", json.string(retained.text)),
                  #(
                    "replay_call_ids",
                    json.array(retained.calls, fn(call) { json.string(call.id) }),
                  ),
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
  }
}

fn message_json(role: String, text: String) -> json.Json {
  json.object([#("role", json.string(role)), #("text", json.string(text))])
}

fn assistant_calls(text: String, calls: List(message.ToolCall)) -> json.Json {
  json.object([
    #("role", json.string("assistant")),
    #("text", json.string(text)),
    #(
      "calls",
      json.array(calls, fn(call) {
        json.object([
          #("id", json.string(call.id)),
          #("name", json.string(call.name)),
          #("arguments", json.string(call.arguments_json)),
        ])
      }),
    ),
  ])
}

fn step(
  state: State,
  event: provider.Event,
) -> Result(#(State, List(message.Progress)), error.Error) {
  case event.event {
    Some("text") -> {
      let next = State(..state, text: state.text <> event.data)
      Ok(#(next, [message.TextDelta("0", event.data)]))
    }
    Some("tool") -> {
      use call <- result.try(parse_call(event.data))
      Ok(#(State(..state, calls: list.append(state.calls, [call])), []))
    }
    Some("done") -> Ok(#(State(..state, done: True), []))
    Some("oversized_done") ->
      Ok(
        #(State(..state, text: event.data, done: True), [
          message.TextDelta("0", event.data),
        ]),
      )
    Some("long_id") -> Ok(#(state, [message.TextDelta(event.data, "x")]))
    Some("batch_over_limit") ->
      Ok(
        #(state, [
          message.TextDelta("0", "ok"),
          message.TextDelta("0", event.data),
        ]),
      )
    Some("metadata_tool") -> {
      let call = message.tool_call("call-1", "calc", "{\"x\":7}")
      Ok(
        #(
          State(
            ..state,
            calls: [message.ToolCall(..call, provider_state: Some(event.data))],
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
            failure: Some(error.Provider(Some("fixture"), event.data)),
          ),
          [],
        ),
      )
    Some("extension") ->
      Ok(#(state, [message.ProviderExtension("scripted-fourth", event.data)]))
    _ -> Ok(#(state, []))
  }
}

fn parse_call(raw: String) -> Result(message.ToolCall, error.Error) {
  case string.split(raw, "|") {
    ["", _, _] -> Error(error.Protocol("Empty fixture call id"))
    [id, name, arguments_json] -> {
      use Nil <- result.try(
        tool.check_name(name)
        |> result.replace_error(error.Protocol("Malformed fixture tool name")),
      )
      Ok(message.tool_call(id, name, arguments_json))
    }
    _ -> Error(error.Protocol("Malformed fixture tool event"))
  }
}

fn terminal(state: State) -> Option(provider.Terminal) {
  case state.done, state.failure, state.refusal, state.limited, state.calls {
    False, _, _, _, _ -> None
    True, Some(failure), _, _, _ -> Some(provider.failed(failure, None))
    True, None, Some(reason), _, _ -> Some(provider.refused(reason, None))
    True, None, None, True, _ ->
      Some(provider.output_limited(state.text, state.calls, None))
    True, None, None, False, [] -> Some(provider.text(state.text, None))
    True, None, None, False, calls ->
      Some(provider.tool_calls(
        state.text,
        calls,
        Some("response-fourth"),
        Some(assistant_calls(state.text, calls) |> json.to_string),
        None,
      ))
  }
}

fn restore_state(saved: String) -> Result(Turn, error.PrepareError) {
  let invalid = fn(reason) {
    error.InvalidRequest(error.InvalidProviderData(reason))
  }
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
  use #(text, raw_calls) <- result.try(
    json.parse(saved, decoder)
    |> result.replace_error(invalid("Invalid fixture replay")),
  )
  use calls <- result.try(
    list.try_map(raw_calls, fn(raw) {
      let #(id, name, arguments) = raw
      use Nil <- result.try(
        tool.check_name(name)
        |> result.replace_error(invalid("Invalid fixture tool")),
      )
      Ok(message.tool_call(id, name, arguments))
    }),
  )
  Ok(Turn(text, calls))
}
