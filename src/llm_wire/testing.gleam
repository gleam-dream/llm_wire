//// Deterministic provider scripting for tests. Nothing here opens a socket or
//// contacts a provider.
////
//// A `Script` is a process holding queued replies. Each request the session
//// runtime would send over the network takes the next reply instead, and the
//// script records the admitted request. Replies enter the same stream owner,
//// SSE framer, reducer, bounds, deadlines, and terminal admission as a real
//// response, so `session.prepare`, `run`, `stream`, and `prepare_continue`
//// behave as they do against a provider.
////
//// Two uses share the script:
////
//// - `config(script)` selects the scripted provider, whose replies are built
////   with `text`, `tool_calls`, `refusal`, and `output_limited`. Tests need no
////   provider wire format.
//// - `with_script(settings, script)` routes any configured provider, built-in
////   or application-defined, through the script. Its replies are that
////   provider's raw SSE bytes in `Events` or `Interrupted`.
////
//// The script is linked to the process that starts it.

import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import llm_wire/config
import llm_wire/internal/api
import llm_wire/internal/transport
import llm_wire/internal/transport_failure
import llm_wire/provider
import llm_wire/types

/// One scripted HTTP exchange.
pub type Reply {
  /// A successful event stream delivered as these chunks, one per read
  /// credit, followed by end of stream. Chunks may split events anywhere.
  Events(chunks: List(String))
  /// These chunks followed by a transport failure before end of stream.
  Interrupted(chunks: List(String))
  /// A non-success HTTP status; no stream opens.
  Status(code: Int, body: String)
}

/// A request the runtime delivered to the script: the admitted request, and
/// the route and body the provider adapter encoded for it.
pub type Recorded {
  Recorded(request: types.Request, path: String, body: String)
}

/// A tool call the scripted provider returns. Its fields are wire values: the
/// runtime admits them exactly as it admits a real provider's call.
pub type ScriptedCall {
  ScriptedCall(id: String, name: String, arguments_json: String)
}

pub opaque type Script {
  Script(subject: process.Subject(Message))
}

type Message {
  Take(request: Recorded, reply_to: process.Subject(Result(Reply, Nil)))
  Requests(reply_to: process.Subject(List(Recorded)))
  Remaining(reply_to: process.Subject(Int))
}

type ScriptState {
  ScriptState(replies: List(Reply), recorded: List(Recorded))
}

/// Starts a script that serves `replies` in order, one per request.
pub fn start(replies: List(Reply)) -> Script {
  let assert Ok(started) =
    actor.new(ScriptState(replies, []))
    |> actor.on_message(handle_message)
    |> actor.start
  Script(started.data)
}

fn handle_message(
  state: ScriptState,
  message: Message,
) -> actor.Next(ScriptState, Message) {
  case message {
    Take(request, reply_to) -> {
      let recorded = [request, ..state.recorded]
      case state.replies {
        [next, ..rest] -> {
          process.send(reply_to, Ok(next))
          actor.continue(ScriptState(rest, recorded))
        }
        [] -> {
          process.send(reply_to, Error(Nil))
          actor.continue(ScriptState([], recorded))
        }
      }
    }
    Requests(reply_to) -> {
      process.send(reply_to, list.reverse(state.recorded))
      actor.continue(state)
    }
    Remaining(reply_to) -> {
      process.send(reply_to, list.length(state.replies))
      actor.continue(state)
    }
  }
}

/// Every request delivered so far, oldest first, including a request that
/// found no remaining reply.
pub fn requests(script: Script) -> List(Recorded) {
  process.call(script.subject, 5000, Requests)
}

/// The number of replies not yet taken.
pub fn remaining(script: Script) -> Int {
  process.call(script.subject, 5000, Remaining)
}

/// Routes every call made with `settings` through the script instead of the
/// network. Preparation, endpoint admission, and the provider's reducer are
/// unchanged; an attached pool is not used. A request with no remaining reply
/// fails with `ConfigurationError`.
pub fn with_script(settings: config.Config, script: Script) -> config.Config {
  config.with_connector(
    settings,
    transport.Connector(fn(prepared, max_chunk, owner, chunk, eof, error, sent) {
      connect(script, prepared, max_chunk, owner, chunk, eof, error, sent)
    }),
  )
}

/// Settings for the scripted provider, routed through `script`.
pub fn config(script: Script) -> config.Config {
  config.from_provider(provider()) |> with_script(script)
}

/// Encodes requests as JSON and reads the replies built by `text`,
/// `tool_calls`, `refusal`, and `output_limited`. It is reachable only through
/// a script, so it is not public.
fn provider() -> provider.Adapter {
  let assert Ok(endpoint) = types.endpoint("https://scripted.llm-wire.invalid")
  provider.adapter(
    provider.Spec(
      identity: types.Custom("scripted"),
      endpoint: endpoint,
      headers: [],
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

// Transport replacement.

type Control {
  More
  Stop
}

fn connect(
  script: Script,
  prepared: api.PreparedCall,
  max_chunk_bytes: Int,
  owner_pid: process.Pid,
  on_chunk: fn(BitArray) -> Nil,
  on_eof: fn() -> Nil,
  on_error: fn(transport_failure.Failure) -> Nil,
  on_request_sent: fn() -> Nil,
) -> Result(transport.TransportHandle, types.WireError) {
  let recorded =
    Recorded(
      api.prepared_request(prepared),
      api.prepared_path(prepared),
      api.prepared_request_json(prepared),
    )
  case process.call(script.subject, 5000, Take(recorded, _)) {
    Error(Nil) ->
      Error(types.ConfigurationError(
        "Test script has no reply left for this request",
      ))
    Ok(Status(code, body)) -> {
      on_request_sent()
      Error(types.HttpStatusError(code, body, None))
    }
    Ok(Events(chunks)) -> {
      on_request_sent()
      Ok(serve(
        chunks,
        False,
        max_chunk_bytes,
        owner_pid,
        on_chunk,
        on_eof,
        on_error,
      ))
    }
    Ok(Interrupted(chunks)) -> {
      on_request_sent()
      Ok(serve(
        chunks,
        True,
        max_chunk_bytes,
        owner_pid,
        on_chunk,
        on_eof,
        on_error,
      ))
    }
  }
}

/// Serves one chunk per read credit, as the network transport does, and stops
/// when the owner closes the stream or exits.
fn serve(
  chunks: List(String),
  interrupted: Bool,
  max_chunk_bytes: Int,
  owner_pid: process.Pid,
  on_chunk: fn(BitArray) -> Nil,
  on_eof: fn() -> Nil,
  on_error: fn(transport_failure.Failure) -> Nil,
) -> transport.TransportHandle {
  let ready = process.new_subject()
  let pid =
    process.spawn_unlinked(fn() {
      let control = process.new_subject()
      process.send(ready, control)
      let selector =
        process.new_selector()
        |> process.select(control)
        |> process.select_specific_monitor(process.monitor(owner_pid), fn(_) {
          Stop
        })
      let finish = fn() {
        case interrupted {
          True ->
            on_error(transport_failure.TransportFailure(
              "scripted connection interrupted",
            ))
          False -> on_eof()
        }
      }
      serve_loop(selector, chunks, max_chunk_bytes, on_chunk, finish, on_error)
    })
  let assert Ok(control) = process.receive(ready, 5000)
  transport.TransportHandle(
    request_more: fn() { process.send(control, More) },
    close: fn() { process.send(control, Stop) },
    owner_pid: pid,
  )
}

fn serve_loop(
  selector: process.Selector(Control),
  chunks: List(String),
  max_chunk_bytes: Int,
  on_chunk: fn(BitArray) -> Nil,
  finish: fn() -> Nil,
  on_error: fn(transport_failure.Failure) -> Nil,
) -> Nil {
  case process.selector_receive_forever(selector) {
    Stop -> Nil
    More ->
      case chunks {
        [] -> finish()
        [chunk, ..rest] ->
          case string.byte_size(chunk) > max_chunk_bytes {
            True ->
              on_error(transport_failure.TransportFailure(
                "response chunk byte limit exceeded",
              ))
            False -> {
              on_chunk(<<chunk:utf8>>)
              case rest {
                [] -> finish()
                _ ->
                  serve_loop(
                    selector,
                    rest,
                    max_chunk_bytes,
                    on_chunk,
                    finish,
                    on_error,
                  )
              }
            }
          }
      }
  }
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
