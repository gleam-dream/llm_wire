import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm_wire/sse
import llm_wire/types

pub opaque type Reducer {
  Reducer(
    limits: types.Limits,
    text_buffers: Dict(String, String),
    text_order: List(String),
    tool_buffers: Dict(String, ToolBuffer),
    tool_order: List(String),
    index_to_item_id: Dict(Int, String),
    active_blocks_count: Int,
    total_text_bytes: Int,
    total_argument_bytes: Int,
    response_bytes_observed: Bool,
    semantic_progress_observed: Bool,
    terminal_outcome: Option(types.TerminalOutcome),
  )
}

type ToolBuffer {
  ToolBuffer(
    call_id: types.CallId,
    name: types.ToolName,
    arguments: String,
    is_done: Bool,
  )
}

pub fn new(limits: types.Limits) -> Reducer {
  Reducer(
    limits: limits,
    text_buffers: dict.new(),
    text_order: [],
    tool_buffers: dict.new(),
    tool_order: [],
    index_to_item_id: dict.new(),
    active_blocks_count: 0,
    total_text_bytes: 0,
    total_argument_bytes: 0,
    response_bytes_observed: False,
    semantic_progress_observed: False,
    terminal_outcome: None,
  )
}

pub fn terminal(reducer: Reducer) -> Option(types.TerminalOutcome) {
  reducer.terminal_outcome
}

pub fn step(
  reducer: Reducer,
  event: sse.ServerSentEvent,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  // If already terminal, reject further events
  case reducer.terminal_outcome {
    Some(_) ->
      Error(types.ProtocolError("Event received after stream terminal"))
    None -> {
      let with_bytes = Reducer(..reducer, response_bytes_observed: True)
      case event.event {
        Some("response.created") -> Ok(#(with_bytes, []))

        Some("response.output_item.added") ->
          handle_output_item_added(with_bytes, event.data)

        Some("response.output_text.delta") | Some("response.text.delta") ->
          handle_output_text_delta(with_bytes, event.data)

        Some("response.function_call_arguments.delta") ->
          handle_function_arguments_delta(with_bytes, event.data)

        Some("response.function_call_arguments.done")
        | Some("response.output_item.done") ->
          handle_output_item_done(with_bytes, event.data)

        Some("response.completed") ->
          handle_response_completed(with_bytes, event.data)

        Some("error") -> handle_error_event(with_bytes, event.data)

        Some(other_event) -> {
          let event_bytes = string.byte_size(other_event)
          case event_bytes > with_bytes.limits.extension_bytes_limit {
            True ->
              Error(types.ResourceLimitExceeded(
                "extension_bytes_limit",
                with_bytes.limits.extension_bytes_limit,
                event_bytes,
              ))
            False ->
              Ok(
                #(with_bytes, [
                  types.ProviderExtension(
                    provider: "openai",
                    event_name: other_event,
                  ),
                ]),
              )
          }
        }

        None -> {
          // Check for data: [DONE]
          case string.trim(event.data) {
            "[DONE]" -> Ok(#(with_bytes, []))
            _ ->
              Ok(
                #(with_bytes, [
                  types.ProviderExtension(
                    provider: "openai",
                    event_name: "data_only",
                  ),
                ]),
              )
          }
        }
      }
    }
  }
}

type OutputItemAdded {
  OutputItemAdded(
    output_index: Int,
    item_id: String,
    item_type: String,
    call_id: Option(String),
    name: Option(String),
  )
}

fn decode_output_item_added() -> decode.Decoder(OutputItemAdded) {
  use output_index <- decode.field("output_index", decode.int)
  use item_id <- decode.subfield(["item", "id"], decode.string)
  use item_type <- decode.subfield(["item", "type"], decode.string)
  use call_id <- decode.optional_field(
    "item",
    None,
    decode.optional_field(
      "call_id",
      None,
      decode.optional(decode.string),
      fn(c) { decode.success(c) },
    ),
  )
  use name <- decode.optional_field(
    "item",
    None,
    decode.optional_field("name", None, decode.optional(decode.string), fn(n) {
      decode.success(n)
    }),
  )
  decode.success(OutputItemAdded(
    output_index,
    item_id,
    item_type,
    call_id,
    name,
  ))
}

fn handle_output_item_added(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case json.parse(data, decode_output_item_added()) {
    Error(_) ->
      Error(types.ProtocolError("Malformed response.output_item.added payload"))
    Ok(added) -> {
      case reducer.active_blocks_count >= reducer.limits.active_blocks_limit {
        True ->
          Error(types.ResourceLimitExceeded(
            "active_blocks_limit",
            reducer.limits.active_blocks_limit,
            reducer.active_blocks_count + 1,
          ))
        False -> {
          case
            dict.has_key(reducer.text_buffers, added.item_id)
            || dict.has_key(reducer.tool_buffers, added.item_id)
          {
            True ->
              Error(types.ProtocolError(
                "Duplicate output item id: " <> added.item_id,
              ))
            False -> {
              let updated_indices =
                dict.insert(
                  reducer.index_to_item_id,
                  added.output_index,
                  added.item_id,
                )
              case added.item_type {
                "message" -> {
                  let updated_text =
                    dict.insert(reducer.text_buffers, added.item_id, "")
                  let updated_order =
                    list.append(reducer.text_order, [added.item_id])
                  Ok(
                    #(
                      Reducer(
                        ..reducer,
                        text_buffers: updated_text,
                        text_order: updated_order,
                        index_to_item_id: updated_indices,
                        active_blocks_count: reducer.active_blocks_count + 1,
                      ),
                      [],
                    ),
                  )
                }
                "function_call" -> {
                  case added.call_id, added.name {
                    Some(cid), Some(nm) -> {
                      case types.call_id(cid), types.tool_name(nm) {
                        Ok(call_id), Ok(tool_name) -> {
                          let buffer =
                            ToolBuffer(
                              call_id: call_id,
                              name: tool_name,
                              arguments: "",
                              is_done: False,
                            )
                          let updated_tools =
                            dict.insert(
                              reducer.tool_buffers,
                              added.item_id,
                              buffer,
                            )
                          let updated_order =
                            list.append(reducer.tool_order, [added.item_id])
                          Ok(
                            #(
                              Reducer(
                                ..reducer,
                                tool_buffers: updated_tools,
                                tool_order: updated_order,
                                index_to_item_id: updated_indices,
                                active_blocks_count: reducer.active_blocks_count
                                  + 1,
                              ),
                              [],
                            ),
                          )
                        }
                        _, _ ->
                          Error(types.ProtocolError(
                            "Invalid call_id or tool_name in function_call",
                          ))
                      }
                    }
                    _, _ ->
                      Error(types.ProtocolError(
                        "function_call missing call_id or name",
                      ))
                  }
                }
                _ -> Ok(#(reducer, []))
              }
            }
          }
        }
      }
    }
  }
}

type TextDeltaPayload {
  TextDeltaPayload(
    output_index: Option(Int),
    item_id: Option(String),
    delta: String,
  )
}

fn decode_text_delta() -> decode.Decoder(TextDeltaPayload) {
  use output_index <- decode.optional_field(
    "output_index",
    None,
    decode.optional(decode.int),
  )
  use item_id <- decode.optional_field(
    "item_id",
    None,
    decode.optional(decode.string),
  )
  use delta <- decode.field("delta", decode.string)
  decode.success(TextDeltaPayload(output_index, item_id, delta))
}

fn handle_output_text_delta(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case json.parse(data, decode_text_delta()) {
    Error(_) ->
      Error(types.ProtocolError("Malformed response.output_text.delta payload"))
    Ok(payload) -> {
      case resolve_item_id(reducer, payload.item_id, payload.output_index) {
        Error(err) -> Error(err)
        Ok(item_id) -> {
          case dict.get(reducer.text_buffers, item_id) {
            Error(Nil) ->
              Error(types.ProtocolError("Unknown text block id: " <> item_id))
            Ok(existing) -> {
              let delta_bytes = string.byte_size(payload.delta)
              let block_bytes = string.byte_size(existing) + delta_bytes
              let total_bytes = reducer.total_text_bytes + delta_bytes

              case block_bytes > reducer.limits.text_bytes_per_block_limit {
                True ->
                  Error(types.ResourceLimitExceeded(
                    "text_bytes_per_block_limit",
                    reducer.limits.text_bytes_per_block_limit,
                    block_bytes,
                  ))
                False ->
                  case total_bytes > reducer.limits.total_text_bytes_limit {
                    True ->
                      Error(types.ResourceLimitExceeded(
                        "total_text_bytes_limit",
                        reducer.limits.total_text_bytes_limit,
                        total_bytes,
                      ))
                    False -> {
                      let updated_buffers =
                        dict.insert(
                          reducer.text_buffers,
                          item_id,
                          existing <> payload.delta,
                        )
                      Ok(
                        #(
                          Reducer(
                            ..reducer,
                            text_buffers: updated_buffers,
                            total_text_bytes: total_bytes,
                            semantic_progress_observed: True,
                          ),
                          [
                            types.TextDelta(
                              block_id: item_id,
                              text: payload.delta,
                            ),
                          ],
                        ),
                      )
                    }
                  }
              }
            }
          }
        }
      }
    }
  }
}

type FunctionDeltaPayload {
  FunctionDeltaPayload(
    output_index: Option(Int),
    item_id: Option(String),
    delta: String,
  )
}

fn decode_function_delta() -> decode.Decoder(FunctionDeltaPayload) {
  use output_index <- decode.optional_field(
    "output_index",
    None,
    decode.optional(decode.int),
  )
  use item_id <- decode.optional_field(
    "item_id",
    None,
    decode.optional(decode.string),
  )
  use delta <- decode.field("delta", decode.string)
  decode.success(FunctionDeltaPayload(output_index, item_id, delta))
}

fn handle_function_arguments_delta(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case json.parse(data, decode_function_delta()) {
    Error(_) ->
      Error(types.ProtocolError(
        "Malformed function_call_arguments.delta payload",
      ))
    Ok(payload) -> {
      case resolve_item_id(reducer, payload.item_id, payload.output_index) {
        Error(err) -> Error(err)
        Ok(item_id) -> {
          case dict.get(reducer.tool_buffers, item_id) {
            Error(Nil) ->
              Error(types.ProtocolError(
                "Unknown tool call block id: " <> item_id,
              ))
            Ok(tool) -> {
              case tool.is_done {
                True ->
                  Error(types.ProtocolError(
                    "Delta received after tool call block completion",
                  ))
                False -> {
                  let delta_bytes = string.byte_size(payload.delta)
                  let tool_bytes =
                    string.byte_size(tool.arguments) + delta_bytes
                  let total_bytes = reducer.total_argument_bytes + delta_bytes

                  case
                    tool_bytes > reducer.limits.argument_bytes_per_call_limit
                  {
                    True ->
                      Error(types.ResourceLimitExceeded(
                        "argument_bytes_per_call_limit",
                        reducer.limits.argument_bytes_per_call_limit,
                        tool_bytes,
                      ))
                    False ->
                      case
                        total_bytes > reducer.limits.total_argument_bytes_limit
                      {
                        True ->
                          Error(types.ResourceLimitExceeded(
                            "total_argument_bytes_limit",
                            reducer.limits.total_argument_bytes_limit,
                            total_bytes,
                          ))
                        False -> {
                          let updated_tool =
                            ToolBuffer(
                              ..tool,
                              arguments: tool.arguments <> payload.delta,
                            )
                          let updated_buffers =
                            dict.insert(
                              reducer.tool_buffers,
                              item_id,
                              updated_tool,
                            )
                          Ok(
                            #(
                              Reducer(
                                ..reducer,
                                tool_buffers: updated_buffers,
                                total_argument_bytes: total_bytes,
                                semantic_progress_observed: True,
                              ),
                              [],
                            ),
                          )
                        }
                      }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

type OutputItemDone {
  OutputItemDone(output_index: Option(Int), item_id: Option(String))
}

fn decode_output_item_done() -> decode.Decoder(OutputItemDone) {
  use output_index <- decode.optional_field(
    "output_index",
    None,
    decode.optional(decode.int),
  )
  use item_id <- decode.optional_field(
    "item",
    None,
    decode.optional_field("id", None, decode.optional(decode.string), fn(id) {
      decode.success(id)
    }),
  )
  decode.success(OutputItemDone(output_index, item_id))
}

fn handle_output_item_done(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case json.parse(data, decode_output_item_done()) {
    Error(_) -> Error(types.ProtocolError("Malformed output_item.done payload"))
    Ok(payload) -> {
      case resolve_item_id(reducer, payload.item_id, payload.output_index) {
        Error(err) -> Error(err)
        Ok(item_id) -> {
          case dict.get(reducer.tool_buffers, item_id) {
            Ok(tool) -> {
              case tool.is_done {
                True ->
                  Error(types.ProtocolError("Duplicate tool block completion"))
                False -> {
                  // Validate that arguments is valid JSON document
                  case json.parse(tool.arguments, decode.dynamic) {
                    Error(_) ->
                      Error(types.ProtocolError(
                        "Invalid JSON in tool call arguments",
                      ))
                    Ok(_) -> {
                      let updated_tool = ToolBuffer(..tool, is_done: True)
                      let updated_buffers =
                        dict.insert(reducer.tool_buffers, item_id, updated_tool)
                      let call =
                        types.ToolCall(
                          id: tool.call_id,
                          name: tool.name,
                          arguments_json: tool.arguments,
                        )
                      Ok(
                        #(
                          Reducer(
                            ..reducer,
                            tool_buffers: updated_buffers,
                            semantic_progress_observed: True,
                          ),
                          [types.ToolCallCompleted(call)],
                        ),
                      )
                    }
                  }
                }
              }
            }
            // If it's a message text block, completing it is a no-op
            Error(Nil) -> Ok(#(reducer, []))
          }
        }
      }
    }
  }
}

type ResponseCompleted {
  ResponseCompleted(id: String, status: String, usage: Option(types.Usage))
}

fn decode_response_completed() -> decode.Decoder(ResponseCompleted) {
  use id <- decode.subfield(["response", "id"], decode.string)
  use status <- decode.subfield(["response", "status"], decode.string)
  use usage <- decode.optional_field(
    "response",
    None,
    decode.optional_field(
      "usage",
      None,
      decode.optional({
        use in_tok <- decode.field("input_tokens", decode.int)
        use out_tok <- decode.field("output_tokens", decode.int)
        use tot_tok <- decode.field("total_tokens", decode.int)
        decode.success(types.Usage(in_tok, out_tok, tot_tok))
      }),
      fn(u) { decode.success(u) },
    ),
  )
  decode.success(ResponseCompleted(id, status, usage))
}

fn handle_response_completed(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case json.parse(data, decode_response_completed()) {
    Error(_) ->
      Error(types.ProtocolError("Malformed response.completed payload"))
    Ok(completed) -> {
      // Check that all started tool calls are finished
      case check_all_tools_completed(reducer.tool_buffers) {
        Error(err) -> Error(err)
        Ok(Nil) -> {
          let all_text =
            list.filter_map(reducer.text_order, fn(id) {
              dict.get(reducer.text_buffers, id)
            })
            |> string.join("")

          let all_calls =
            list.filter_map(reducer.tool_order, fn(id) {
              case dict.get(reducer.tool_buffers, id) {
                Ok(tb) ->
                  Ok(types.ToolCall(
                    id: tb.call_id,
                    name: tb.name,
                    arguments_json: tb.arguments,
                  ))
                Error(Nil) -> Error(Nil)
              }
            })

          let retry_evidence =
            types.RetryEvidence(
              classification: types.RequestMayHaveReachedProvider,
              response_bytes_observed: reducer.response_bytes_observed,
              semantic_progress_observed: reducer.semantic_progress_observed,
            )

          let terminal = case completed.status {
            "completed" -> {
              let outcome = case all_calls {
                [] -> types.CompletedText(all_text)
                _ -> types.CompletedToolCalls(all_text, all_calls)
              }
              types.StreamFinished(outcome: outcome, usage: completed.usage)
            }
            "incomplete" -> {
              let outcome = types.OutputLimited(all_text, all_calls)
              types.StreamFinished(outcome: outcome, usage: completed.usage)
            }
            "failed" -> {
              types.StreamFailed(
                error: types.ProviderError(
                  code: None,
                  message: "Response completed with status failed",
                ),
                retry: retry_evidence,
              )
            }
            "cancelled" -> {
              types.StreamCancelledLocally(retry: retry_evidence)
            }
            other -> {
              types.StreamFailed(
                error: types.ProviderError(
                  code: None,
                  message: "Unknown response completion status: " <> other,
                ),
                retry: retry_evidence,
              )
            }
          }

          let progress = case completed.usage {
            Some(u) -> [types.UsageUpdate(u)]
            None -> []
          }

          Ok(#(
            Reducer(
              ..reducer,
              terminal_outcome: Some(terminal),
              semantic_progress_observed: True,
            ),
            progress,
          ))
        }
      }
    }
  }
}

type ErrorPayload {
  ErrorPayload(code: Option(String), message: String)
}

fn decode_error_payload() -> decode.Decoder(ErrorPayload) {
  use code <- decode.optional_field(
    "error",
    None,
    decode.optional_field("code", None, decode.optional(decode.string), fn(c) {
      decode.success(c)
    }),
  )
  use message <- decode.subfield(["error", "message"], decode.string)
  decode.success(ErrorPayload(code, message))
}

fn handle_error_event(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case json.parse(data, decode_error_payload()) {
    Error(_) -> Error(types.ProtocolError("Malformed error event payload"))
    Ok(err) -> {
      let retry_evidence =
        types.RetryEvidence(
          classification: types.RequestMayHaveReachedProvider,
          response_bytes_observed: reducer.response_bytes_observed,
          semantic_progress_observed: reducer.semantic_progress_observed,
        )
      let terminal =
        types.StreamFailed(
          error: types.ProviderError(code: err.code, message: err.message),
          retry: retry_evidence,
        )
      Ok(#(Reducer(..reducer, terminal_outcome: Some(terminal)), []))
    }
  }
}

fn resolve_item_id(
  reducer: Reducer,
  maybe_item_id: Option(String),
  maybe_output_index: Option(Int),
) -> Result(String, types.WireError) {
  case maybe_item_id {
    Some(id) -> Ok(id)
    None ->
      case maybe_output_index {
        Some(idx) ->
          case dict.get(reducer.index_to_item_id, idx) {
            Ok(id) -> Ok(id)
            Error(Nil) ->
              Error(types.ProtocolError(
                "Unmapped output_index: " <> string.inspect(idx),
              ))
          }
        None ->
          Error(types.ProtocolError("Event missing item_id and output_index"))
      }
  }
}

fn check_all_tools_completed(
  tools: Dict(String, ToolBuffer),
) -> Result(Nil, types.WireError) {
  dict.fold(tools, Ok(Nil), fn(acc, id, tool) {
    case acc {
      Error(e) -> Error(e)
      Ok(Nil) ->
        case tool.is_done {
          True -> Ok(Nil)
          False ->
            Error(types.ProtocolError(
              "Tool call still incomplete at completion: " <> id,
            ))
        }
    }
  })
}
