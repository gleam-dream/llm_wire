//// Builds scripted LLM replies and lowers them into HTTP Gun exchanges for
//// tests.
////
//// Use `text`, `tool_calls`, `refusal` and `output_limited` to describe a
//// reply, `exchange` to pair it with a prepared call, and give the exchanges
//// to an `http_gun/testing` client. The calls then run through the ordinary
//// `llm_wire/session` path. `config()` selects a provider-neutral scripted
//// adapter. Client startup, matching, recording and playback belong to
//// HTTP Gun. Recorded requests drop HTTP Gun's documented credential headers.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import http_gun/error as http_error
import http_gun/testing as http_testing
import llm_wire/config
import llm_wire/provider
import llm_wire/session
import llm_wire/types

/// One scripted HTTP exchange.
pub type Reply {
  /// A successful event stream delivered as these chunks, one per read
  /// credit, followed by end of stream. Chunks may split events anywhere.
  Events(chunks: List(String))
  /// These chunks followed by a transport failure before end of stream.
  Interrupted(chunks: List(String))
  /// An HTTP status other than the expected 200; the semantic stream fails.
  Status(code: Int, body: String)
}

/// A tool call the scripted provider returns. Its fields are wire values: the
/// runtime admits them exactly as it admits a real provider's call.
pub type ScriptedCall {
  ScriptedCall(id: String, name: String, arguments_json: String)
}

/// Encodes requests as JSON and reads the replies built by `text`,
/// `tool_calls`, `refusal`, and `output_limited`. It is reachable only through
/// HTTP Gun scripts and local test servers.
fn provider() -> provider.Adapter {
  let assert Ok(endpoint) = types.endpoint("https://scripted.llm-wire.invalid")
  provider.adapter(
    provider.Spec(
      identity: types.Custom("scripted"),
      endpoint: endpoint,
      headers: fn() { [] },
      encode: encode_request,
      project_tool_schema: provider.blueprint_schema,
      project_output_schema: provider.blueprint_schema,
      new_reducer: fn(_limits, _tools) {
        Ok(
          provider.reducer(
            Turn(text: "", calls: [], usage: None, terminal: None),
            step,
            fn(state: Turn) { state.terminal },
            fn(_state, fallback) { types.RetryEvidence(fallback, False, False) },
          ),
        )
      },
    ),
  )
}

/// A final text answer. Non-empty text streams as one `TextDelta`.
pub fn text(text: String) -> Reply {
  Events(list.append(text_events(text), [end_event("complete", "")]))
}

/// Tool calls, optionally with assistant text, awaiting results.
pub fn tool_calls(text: String, calls: List(ScriptedCall)) -> Reply {
  Events(
    list.flatten([
      text_events(text),
      list.map(calls, call_event),
      [end_event("tool_calls", "")],
    ]),
  )
}

/// A refusal with its reason.
pub fn refusal(reason: String) -> Reply {
  Events([end_event("refusal", reason)])
}

/// Output cut off at the token limit after `partial_text`.
pub fn output_limited(partial_text: String) -> Reply {
  Events(list.append(text_events(partial_text), [end_event("length", "")]))
}

/// Reports `usage` before the reply's terminal event. A `Status` reply is
/// unchanged. Only the scripted provider reads the usage event.
pub fn with_usage(reply: Reply, usage: types.Usage) -> Reply {
  let event =
    sse_event(
      "usage",
      json.object([
        #("input_tokens", json.int(usage.input_tokens)),
        #("output_tokens", json.int(usage.output_tokens)),
        #("total_tokens", json.int(usage.total_tokens)),
      ]),
    )
  case reply {
    Events(chunks) -> Events([event, ..chunks])
    Interrupted(chunks) -> Interrupted([event, ..chunks])
    Status(..) -> reply
  }
}

fn text_events(text: String) -> List(String) {
  case text {
    "" -> []
    _ -> [sse_event("text", json.object([#("text", json.string(text))]))]
  }
}

fn call_event(call: ScriptedCall) -> String {
  sse_event(
    "tool_call",
    json.object([
      #("id", json.string(call.id)),
      #("name", json.string(call.name)),
      #("arguments", json.string(call.arguments_json)),
    ]),
  )
}

fn end_event(stop: String, reason: String) -> String {
  sse_event(
    "end",
    json.object([#("stop", json.string(stop)), #("reason", json.string(reason))]),
  )
}

fn sse_event(name: String, data: json.Json) -> String {
  "event: " <> name <> "\ndata: " <> json.to_string(data) <> "\n\n"
}

// Scripted provider wire format.

type Turn {
  Turn(
    text: String,
    calls: List(types.ToolCall),
    usage: Option(types.Usage),
    terminal: Option(provider.Terminal),
  )
}

fn encode_request(
  request: types.Request,
  tools: List(provider.ProjectedTool),
  format: Option(provider.OutputFormat),
) -> Result(provider.EncodedRequest, types.WireError) {
  let body =
    json.object([
      #("model", json.string(types.model_id_to_string(request.model))),
      #("messages", json.array(request.messages, encode_message)),
      #(
        "tools",
        json.array(tools, fn(tool) {
          json.object([
            #("name", json.string(types.tool_name_to_string(tool.name))),
            #("description", json.string(tool.description)),
            #("schema", tool.schema),
          ])
        }),
      ),
      #(
        "output",
        json.nullable(format, fn(format) {
          json.object([
            #("name", json.string(format.name)),
            #("schema", format.schema),
          ])
        }),
      ),
    ])
  Ok(provider.EncodedRequest("/scripted", json.to_string(body)))
}

fn encode_message(message: types.Message) -> json.Json {
  case message {
    types.SystemMessage(content) -> role_text("system", content)
    types.UserMessage(content) -> role_text("user", content)
    types.AssistantMessage(content) -> role_text("assistant", content)
    types.UserContent(parts) -> role_parts("user", parts)
    types.AssistantContent(parts) -> role_parts("assistant", parts)
    types.AssistantTurnMessage(turn) -> assistant_calls(turn.text, turn.calls)
    types.AssistantToolCalls(calls) -> assistant_calls("", calls)
    types.AssistantToolCallsWithText(text, calls) ->
      assistant_calls(text, calls)
    types.ToolResultMessage(call_id, content) ->
      json.object([
        #("role", json.string("tool")),
        #("call_id", json.string(types.call_id_to_string(call_id))),
        #("content", json.string(content)),
      ])
  }
}

fn role_text(role: String, content: String) -> json.Json {
  json.object([#("role", json.string(role)), #("content", json.string(content))])
}

fn role_parts(role: String, parts: List(types.Content)) -> json.Json {
  json.object([
    #("role", json.string(role)),
    #(
      "parts",
      json.array(parts, fn(part) {
        case part {
          types.TextContent(text) -> json.object([#("text", json.string(text))])
          types.ImageUrlContent(url) ->
            json.object([#("image_url", json.string(url))])
          types.InlineImageContent(mime_type, data) ->
            json.object([
              #("mime_type", json.string(mime_type)),
              #("data", json.string(data)),
            ])
        }
      }),
    ),
  ])
}

fn assistant_calls(text: String, calls: List(types.ToolCall)) -> json.Json {
  json.object([
    #("role", json.string("assistant")),
    #("content", json.string(text)),
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
  turn: Turn,
  event: provider.Event,
) -> Result(#(Turn, List(types.StreamProgress)), types.WireError) {
  case turn.terminal, event.event {
    Some(_), _ -> Error(types.ProtocolError("Scripted event after end"))
    None, Some("text") -> {
      use text <- parse(event.data, decode.at(["text"], decode.string))
      Ok(#(Turn(..turn, text: turn.text <> text), [types.TextDelta("0", text)]))
    }
    None, Some("tool_call") -> {
      use call <- parse(event.data, {
        use id <- decode.field("id", decode.string)
        use name <- decode.field("name", decode.string)
        use arguments <- decode.field("arguments", decode.string)
        decode.success(#(id, name, arguments))
      })
      let #(raw_id, raw_name, arguments) = call
      case types.call_id(raw_id), types.provider_tool_name(raw_name) {
        Ok(id), Ok(name) ->
          Ok(
            #(
              Turn(..turn, calls: [
                types.tool_call(id, name, arguments),
                ..turn.calls
              ]),
              [],
            ),
          )
        Error(error), _ | _, Error(error) -> Error(error)
      }
    }
    None, Some("usage") -> {
      use usage <- parse(event.data, {
        use input <- decode.field("input_tokens", decode.int)
        use output <- decode.field("output_tokens", decode.int)
        use total <- decode.field("total_tokens", decode.int)
        decode.success(types.Usage(input, output, total))
      })
      Ok(#(Turn(..turn, usage: Some(usage)), [types.UsageUpdate(usage)]))
    }
    None, Some("end") -> {
      use #(stop, reason) <- parse(event.data, {
        use stop <- decode.field("stop", decode.string)
        use reason <- decode.field("reason", decode.string)
        decode.success(#(stop, reason))
      })
      let calls = list.reverse(turn.calls)
      let terminal = case stop, calls {
        "complete", [] -> Ok(provider.Text(turn.text, turn.usage))
        "tool_calls", [_, ..] ->
          Ok(provider.ToolCalls(turn.text, calls, None, None, turn.usage))
        "refusal", [] -> Ok(provider.Refusal(reason, turn.usage))
        "length", _ -> Ok(provider.OutputLimited(turn.text, calls, turn.usage))
        _, _ ->
          Error(types.ProtocolError(
            "Scripted end does not match its calls: "
            <> stop
            <> " with "
            <> int.to_string(list.length(calls))
            <> " calls",
          ))
      }
      case terminal {
        Ok(value) -> Ok(#(Turn(..turn, terminal: Some(value)), []))
        Error(error) -> Error(error)
      }
    }
    None, other ->
      Error(types.ProtocolError(
        "Unknown scripted event: " <> option.unwrap(other, "<unnamed>"),
      ))
  }
}

fn parse(
  data: String,
  decoder: decode.Decoder(a),
  next: fn(a) -> Result(b, types.WireError),
) -> Result(b, types.WireError) {
  case json.parse(data, decoder) {
    Ok(value) -> next(value)
    Error(_) -> Error(types.ProtocolError("Malformed scripted event: " <> data))
  }
}

/// One finite HTTP Gun exchange from an opaque admitted call. Credential
/// metadata follows HTTP Gun's finite exclusion list; bodies/queries stay exact.
pub fn exchange(
  prepared: session.PreparedCall,
  reply: Reply,
) -> http_testing.Exchange {
  session.fixture_exchange(prepared, http_reply(reply))
}

pub fn structured_exchange(
  prepared: session.PreparedStructuredCall(output),
  reply: Reply,
) -> http_testing.Exchange {
  session.structured_fixture_exchange(prepared, http_reply(reply))
}

pub fn http_reply(reply: Reply) -> http_testing.Reply {
  let #(status, chunks, ending) = case reply {
    Events(chunks) -> #(200, chunks, http_testing.Finished([]))
    Interrupted(chunks) -> #(
      200,
      chunks,
      http_testing.Aborted(http_error.new(
        http_error.RequestFailed(http_error.PeerClosed),
        http_error.MaybeSent,
      )),
    )
    Status(code, text) -> #(code, [text], http_testing.Finished([]))
  }
  http_testing.Respond(
    response.new(status)
      |> response.set_header("content-type", "text/event-stream")
      |> response.set_body(list.map(chunks, bit_array.from_string)),
    ending,
  )
}

pub fn config() -> config.Config {
  config.from_provider(provider())
}
