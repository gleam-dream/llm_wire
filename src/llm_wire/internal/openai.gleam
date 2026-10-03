import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm_wire/error
import llm_wire/internal/ids
import llm_wire/internal/limits
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/limit
import llm_wire/message

pub opaque type Reducer {
  Reducer(
    limits: limits.Limits,
    text_buffers: Dict(String, String),
    text_order: List(String),
    text_done: Dict(String, Bool),
    refusal_buffers: Dict(String, String),
    refusal_order: List(String),
    reasoning_buffers: Dict(String, String),
    reasoning_order: List(String),
    reasoning_done: Dict(String, Bool),
    tool_buffers: Dict(String, ToolBuffer),
    tool_order: List(String),
    index_to_item_id: Dict(Int, String),
    seen_call_ids: List(String),
    active_blocks_count: Int,
    total_text_bytes: Int,
    total_argument_bytes: Int,
    response_bytes_observed: Bool,
    semantic_progress_observed: Bool,
    terminal_outcome: Option(stream_types.TerminalOutcome),
  )
}

type ToolBuffer {
  ToolBuffer(call_id: String, name: String, arguments: String, is_done: Bool)
}

pub fn new(limits: limits.Limits) -> Reducer {
  Reducer(
    limits: limits,
    text_buffers: dict.new(),
    text_order: [],
    text_done: dict.new(),
    refusal_buffers: dict.new(),
    refusal_order: [],
    reasoning_buffers: dict.new(),
    reasoning_order: [],
    reasoning_done: dict.new(),
    tool_buffers: dict.new(),
    tool_order: [],
    index_to_item_id: dict.new(),
    seen_call_ids: [],
    active_blocks_count: 0,
    total_text_bytes: 0,
    total_argument_bytes: 0,
    response_bytes_observed: False,
    semantic_progress_observed: False,
    terminal_outcome: None,
  )
}

pub fn terminal(reducer: Reducer) -> Option(stream_types.TerminalOutcome) {
  reducer.terminal_outcome
}

pub fn retry_evidence(
  reducer: Reducer,
  fallback_classification: stream_types.RetryClassification,
) -> stream_types.RetryEvidence {
  let classification = case reducer.semantic_progress_observed {
    True ->
      case list.is_empty(reducer.tool_order) {
        False -> stream_types.EffectUnknown
        True -> fallback_classification
      }
    False -> fallback_classification
  }
  stream_types.RetryEvidence(
    classification: classification,
    response_bytes_observed: reducer.response_bytes_observed,
    semantic_progress_observed: reducer.semantic_progress_observed,
  )
}

pub fn step(
  reducer: Reducer,
  event: sse.ServerSentEvent,
) -> Result(#(Reducer, List(message.Progress)), error.Error) {
  // If already terminal, reject further events
  case reducer.terminal_outcome {
    Some(_) -> Error(error.Protocol("Event received after stream terminal"))
    None -> {
      let with_bytes = Reducer(..reducer, response_bytes_observed: True)
      case event.event {
        Some("response.created") -> Ok(#(with_bytes, []))

        Some("response.output_item.added") ->
          handle_output_item_added(with_bytes, event.data)

        Some("response.output_text.delta") | Some("response.text.delta") ->
          handle_output_text_delta(with_bytes, event.data)

        Some("response.refusal.delta") ->
          handle_refusal_delta(with_bytes, event.data)

        Some("response.reasoning_summary_text.delta") ->
          handle_reasoning_delta(with_bytes, event.data)

        Some("response.function_call_arguments.delta") ->
          handle_function_arguments_delta(with_bytes, event.data)

        Some("response.function_call_arguments.done")
        | Some("response.output_item.done") ->
          handle_output_item_done(with_bytes, event.data)

        // `response.incomplete` carries the same response object with
        // status "incomplete", which ends the stream as an output limit.
        Some("response.completed") | Some("response.incomplete") ->
          handle_response_completed(with_bytes, event.data)

        Some("response.failed") ->
          handle_response_failed(with_bytes, event.data)

        Some("error") -> handle_error_event(with_bytes, event.data)

        Some(other_event) -> {
          let event_bytes = string.byte_size(other_event)
          case event_bytes > with_bytes.limits.extension_bytes_limit {
            True ->
              Error(error.LimitExceeded(
                limit.ExtensionBytes,
                with_bytes.limits.extension_bytes_limit,
                event_bytes,
              ))
            False ->
              Ok(
                #(with_bytes, [
                  message.ProviderExtension(
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
                  message.ProviderExtension(
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
) -> Result(#(Reducer, List(message.Progress)), error.Error) {
  case json.parse(data, decode_output_item_added()) {
    Error(_) ->
      Error(error.Protocol("Malformed response.output_item.added payload"))
    Ok(added) -> {
      case reducer.active_blocks_count >= reducer.limits.active_blocks_limit {
        True ->
          Error(error.LimitExceeded(
            limit.ActiveBlocks,
            reducer.limits.active_blocks_limit,
            reducer.active_blocks_count + 1,
          ))
        False -> {
          case dict.has_key(reducer.index_to_item_id, added.output_index) {
            True ->
              Error(error.Protocol(
                "Duplicate output_index in output_item.added: "
                <> int.to_string(added.output_index),
              ))
            False -> {
              case
                dict.has_key(reducer.text_buffers, added.item_id)
                || dict.has_key(reducer.reasoning_buffers, added.item_id)
                || dict.has_key(reducer.tool_buffers, added.item_id)
              {
                True ->
                  Error(error.Protocol(
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
                      let updated_done =
                        dict.insert(reducer.text_done, added.item_id, False)
                      Ok(
                        #(
                          Reducer(
                            ..reducer,
                            text_buffers: updated_text,
                            text_order: updated_order,
                            text_done: updated_done,
                            index_to_item_id: updated_indices,
                            active_blocks_count: reducer.active_blocks_count + 1,
                          ),
                          [],
                        ),
                      )
                    }
                    "reasoning" -> {
                      let updated_reasoning =
                        dict.insert(
                          reducer.reasoning_buffers,
                          added.item_id,
                          "",
                        )
                      let updated_order =
                        list.append(reducer.reasoning_order, [added.item_id])
                      let updated_done =
                        dict.insert(
                          reducer.reasoning_done,
                          added.item_id,
                          False,
                        )
                      Ok(
                        #(
                          Reducer(
                            ..reducer,
                            reasoning_buffers: updated_reasoning,
                            reasoning_order: updated_order,
                            reasoning_done: updated_done,
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
                          case list.contains(reducer.seen_call_ids, cid) {
                            True ->
                              Error(error.Protocol(
                                "Duplicate tool call id: " <> cid,
                              ))
                            False -> {
                              case
                                ids.call_id(cid),
                                ids.provider_tool_name(nm)
                              {
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
                                    list.append(reducer.tool_order, [
                                      added.item_id,
                                    ])
                                  let updated_seen_calls = [
                                    cid,
                                    ..reducer.seen_call_ids
                                  ]
                                  Ok(
                                    #(
                                      Reducer(
                                        ..reducer,
                                        tool_buffers: updated_tools,
                                        tool_order: updated_order,
                                        index_to_item_id: updated_indices,
                                        seen_call_ids: updated_seen_calls,
                                        active_blocks_count: reducer.active_blocks_count
                                          + 1,
                                      ),
                                      [],
                                    ),
                                  )
                                }
                                Error(error), _ | _, Error(error) ->
                                  Error(error)
                              }
                            }
                          }
                        }
                        _, _ ->
                          Error(error.Protocol(
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
) -> Result(#(Reducer, List(message.Progress)), error.Error) {
  case json.parse(data, decode_text_delta()) {
    Error(_) ->
      Error(error.Protocol("Malformed response.output_text.delta payload"))
    Ok(payload) -> {
      case resolve_item_id(reducer, payload.item_id, payload.output_index) {
        Error(err) -> Error(err)
        Ok(item_id) ->
          case dict.get(reducer.text_done, item_id) {
            Ok(True) ->
              Error(error.Protocol(
                "Text delta received after message completion",
              ))
            _ -> handle_text_delta(reducer, item_id, payload.delta)
          }
      }
    }
  }
}

fn handle_text_delta(
  reducer: Reducer,
  item_id: String,
  delta: String,
) -> Result(#(Reducer, List(message.Progress)), error.Error) {
  case dict.get(reducer.text_buffers, item_id) {
    Error(Nil) -> Error(error.Protocol("Unknown text block id: " <> item_id))
    Ok(existing) -> {
      let delta_bytes = string.byte_size(delta)
      let block_bytes = string.byte_size(existing) + delta_bytes
      let total_bytes = reducer.total_text_bytes + delta_bytes

      case block_bytes > reducer.limits.text_bytes_per_block_limit {
        True ->
          Error(error.LimitExceeded(
            limit.TextBytesPerBlock,
            reducer.limits.text_bytes_per_block_limit,
            block_bytes,
          ))
        False ->
          case total_bytes > reducer.limits.total_text_bytes_limit {
            True ->
              Error(error.LimitExceeded(
                limit.TotalTextBytes,
                reducer.limits.total_text_bytes_limit,
                total_bytes,
              ))
            False -> {
              let updated_buffers =
                dict.insert(reducer.text_buffers, item_id, existing <> delta)
              Ok(
                #(
                  Reducer(
                    ..reducer,
                    text_buffers: updated_buffers,
                    total_text_bytes: total_bytes,
                    semantic_progress_observed: True,
                  ),
                  [message.TextDelta(block_id: item_id, text: delta)],
                ),
              )
            }
          }
      }
    }
  }
}

fn handle_refusal_delta(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(message.Progress)), error.Error) {
  case json.parse(data, decode_text_delta()) {
    Error(_) ->
      Error(error.Protocol("Malformed response.refusal.delta payload"))
    Ok(payload) -> {
      case resolve_item_id(reducer, payload.item_id, payload.output_index) {
        Error(err) -> Error(err)
        Ok(item_id) ->
          case dict.get(reducer.text_buffers, item_id) {
            Error(Nil) ->
              Error(error.Protocol("Unknown refusal block id: " <> item_id))
            Ok(text_so_far) ->
              case dict.get(reducer.text_done, item_id) {
                Ok(True) ->
                  Error(error.Protocol(
                    "Refusal delta received after message completion",
                  ))
                _ -> {
                  let refusal_so_far = case
                    dict.get(reducer.refusal_buffers, item_id)
                  {
                    Ok(text) -> text
                    Error(Nil) -> ""
                  }
                  let delta_bytes = string.byte_size(payload.delta)
                  let block_bytes =
                    string.byte_size(text_so_far)
                    + string.byte_size(refusal_so_far)
                    + delta_bytes
                  let total_bytes = reducer.total_text_bytes + delta_bytes
                  case block_bytes > reducer.limits.text_bytes_per_block_limit {
                    True ->
                      Error(error.LimitExceeded(
                        limit.TextBytesPerBlock,
                        reducer.limits.text_bytes_per_block_limit,
                        block_bytes,
                      ))
                    False ->
                      case total_bytes > reducer.limits.total_text_bytes_limit {
                        True ->
                          Error(error.LimitExceeded(
                            limit.TotalTextBytes,
                            reducer.limits.total_text_bytes_limit,
                            total_bytes,
                          ))
                        False -> {
                          let updated_buffers =
                            dict.insert(
                              reducer.refusal_buffers,
                              item_id,
                              refusal_so_far <> payload.delta,
                            )
                          let updated_order = case
                            dict.has_key(reducer.refusal_buffers, item_id)
                          {
                            True -> reducer.refusal_order
                            False ->
                              list.append(reducer.refusal_order, [item_id])
                          }
                          Ok(
                            #(
                              Reducer(
                                ..reducer,
                                refusal_buffers: updated_buffers,
                                refusal_order: updated_order,
                                total_text_bytes: total_bytes,
                                semantic_progress_observed: True,
                              ),
                              [
                                message.RefusalDelta(
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

fn handle_reasoning_delta(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(message.Progress)), error.Error) {
  case json.parse(data, decode_text_delta()) {
    Error(_) ->
      Error(error.Protocol(
        "Malformed response.reasoning_summary_text.delta payload",
      ))
    Ok(payload) -> {
      case resolve_item_id(reducer, payload.item_id, payload.output_index) {
        Error(err) -> Error(err)
        Ok(item_id) ->
          case dict.get(reducer.reasoning_buffers, item_id) {
            Error(Nil) ->
              Error(error.Protocol("Unknown reasoning block id: " <> item_id))
            Ok(existing) ->
              case dict.get(reducer.reasoning_done, item_id) {
                Ok(True) ->
                  Error(error.Protocol(
                    "Reasoning delta received after block completion",
                  ))
                _ -> {
                  let delta_bytes = string.byte_size(payload.delta)
                  let block_bytes = string.byte_size(existing) + delta_bytes
                  let total_bytes = reducer.total_text_bytes + delta_bytes
                  case block_bytes > reducer.limits.text_bytes_per_block_limit {
                    True ->
                      Error(error.LimitExceeded(
                        limit.TextBytesPerBlock,
                        reducer.limits.text_bytes_per_block_limit,
                        block_bytes,
                      ))
                    False ->
                      case total_bytes > reducer.limits.total_text_bytes_limit {
                        True ->
                          Error(error.LimitExceeded(
                            limit.TotalTextBytes,
                            reducer.limits.total_text_bytes_limit,
                            total_bytes,
                          ))
                        False -> {
                          let updated_buffers =
                            dict.insert(
                              reducer.reasoning_buffers,
                              item_id,
                              existing <> payload.delta,
                            )
                          Ok(
                            #(
                              Reducer(
                                ..reducer,
                                reasoning_buffers: updated_buffers,
                                total_text_bytes: total_bytes,
                                semantic_progress_observed: True,
                              ),
                              [
                                message.ReasoningDelta(
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
) -> Result(#(Reducer, List(message.Progress)), error.Error) {
  case json.parse(data, decode_function_delta()) {
    Error(_) ->
      Error(error.Protocol("Malformed function_call_arguments.delta payload"))
    Ok(payload) -> {
      case resolve_item_id(reducer, payload.item_id, payload.output_index) {
        Error(err) -> Error(err)
        Ok(item_id) -> {
          case dict.get(reducer.tool_buffers, item_id) {
            Error(Nil) ->
              Error(error.Protocol("Unknown tool call block id: " <> item_id))
            Ok(tool) -> {
              case tool.is_done {
                True ->
                  Error(error.Protocol(
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
                      Error(error.LimitExceeded(
                        limit.ArgumentBytesPerCall,
                        reducer.limits.argument_bytes_per_call_limit,
                        tool_bytes,
                      ))
                    False ->
                      case
                        total_bytes > reducer.limits.total_argument_bytes_limit
                      {
                        True ->
                          Error(error.LimitExceeded(
                            limit.TotalArgumentBytes,
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
                              case payload.delta {
                                "" -> []
                                delta -> [
                                  message.ToolArgumentsDelta(
                                    tool.call_id,
                                    delta,
                                  ),
                                ]
                              },
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
) -> Result(#(Reducer, List(message.Progress)), error.Error) {
  case json.parse(data, decode_output_item_done()) {
    Error(_) -> Error(error.Protocol("Malformed output_item.done payload"))
    Ok(payload) -> {
      case resolve_item_id(reducer, payload.item_id, payload.output_index) {
        Error(err) -> Error(err)
        Ok(item_id) -> {
          case dict.get(reducer.tool_buffers, item_id) {
            Ok(tool) -> {
              case tool.is_done {
                True -> Error(error.Protocol("Duplicate tool block completion"))
                False -> {
                  // Catalog and schema admission belong to the runtime's
                  // terminal check, which may report rather than reject.
                  let updated_tool = ToolBuffer(..tool, is_done: True)
                  let updated_buffers =
                    dict.insert(reducer.tool_buffers, item_id, updated_tool)
                  Ok(
                    #(
                      Reducer(
                        ..reducer,
                        tool_buffers: updated_buffers,
                        semantic_progress_observed: True,
                      ),
                      [],
                    ),
                  )
                }
              }
            }
            Error(Nil) -> {
              case dict.get(reducer.text_buffers, item_id) {
                Ok(_) -> {
                  let updated_done =
                    dict.insert(reducer.text_done, item_id, True)
                  Ok(#(Reducer(..reducer, text_done: updated_done), []))
                }
                Error(Nil) ->
                  case dict.get(reducer.reasoning_buffers, item_id) {
                    Ok(_) -> {
                      let updated_done =
                        dict.insert(reducer.reasoning_done, item_id, True)
                      Ok(
                        #(Reducer(..reducer, reasoning_done: updated_done), []),
                      )
                    }
                    Error(Nil) ->
                      Error(error.Protocol(
                        "Unknown output item completed: " <> item_id,
                      ))
                  }
              }
            }
          }
        }
      }
    }
  }
}

type ResponseCompleted {
  ResponseCompleted(id: String, status: String, usage: Option(message.Usage))
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
        decode.success(message.Usage(in_tok, out_tok, tot_tok))
      }),
      fn(u) { decode.success(u) },
    ),
  )
  decode.success(ResponseCompleted(id, status, usage))
}

/// The `response.error` object of a failed response: `code` and `message`
/// (openai-python `ResponseError`), each absent when the object is null.
fn response_error(data: String) -> #(Option(String), String) {
  let code =
    decode.one_of(
      decode.at(["response", "error", "code"], decode.map(decode.string, Some)),
      [decode.success(None)],
    )
  let reason =
    decode.one_of(decode.at(["response", "error", "message"], decode.string), [
      decode.success("Response completed with status failed"),
    ])
  let decoder = {
    use code <- decode.then(code)
    use reason <- decode.then(reason)
    decode.success(#(code, reason))
  }
  case json.parse(data, decoder) {
    Ok(found) -> found
    Error(_) -> #(None, "Response completed with status failed")
  }
}

fn handle_response_failed(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(message.Progress)), error.Error) {
  let #(code, reason) = response_error(data)
  let terminal =
    stream_types.StreamFailed(
      error: error.Provider(code:, message: reason),
      retry: stream_types.RetryEvidence(
        classification: stream_types.RequestMayHaveReachedProvider,
        response_bytes_observed: reducer.response_bytes_observed,
        semantic_progress_observed: reducer.semantic_progress_observed,
      ),
    )
  Ok(#(Reducer(..reducer, terminal_outcome: Some(terminal)), []))
}

fn handle_response_completed(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(message.Progress)), error.Error) {
  case json.parse(data, decode_response_completed()) {
    Error(_) -> Error(error.Protocol("Malformed response.completed payload"))
    Ok(completed) -> {
      // Check that all started text blocks are finished
      use Nil <- result.try(check_all_text_completed(
        reducer.text_done,
        reducer.text_order,
      ))
      use Nil <- result.try(check_all_reasoning_completed(
        reducer.reasoning_done,
        reducer.reasoning_order,
      ))
      // Check that all started tool calls are finished
      case check_all_tools_completed(reducer.tool_buffers) {
        Error(err) -> Error(err)
        Ok(Nil) -> {
          let all_text =
            list.filter_map(reducer.text_order, fn(id) {
              dict.get(reducer.text_buffers, id)
            })
            |> string.join("")

          let refusal_text =
            list.filter_map(reducer.refusal_order, fn(id) {
              dict.get(reducer.refusal_buffers, id)
            })
            |> string.join("")

          let all_calls =
            list.filter_map(reducer.tool_order, fn(id) {
              case dict.get(reducer.tool_buffers, id) {
                Ok(tb) ->
                  Ok(message.ToolCall(
                    id: tb.call_id,
                    name: tb.name,
                    arguments_json: tb.arguments,
                    provider_id: Some(tb.call_id),
                    provider_state: None,
                  ))
                Error(Nil) -> Error(Nil)
              }
            })

          let retry_evidence =
            stream_types.RetryEvidence(
              classification: stream_types.RequestMayHaveReachedProvider,
              response_bytes_observed: reducer.response_bytes_observed,
              semantic_progress_observed: reducer.semantic_progress_observed,
            )

          let terminal = case completed.status {
            "completed" -> {
              let outcome = case refusal_text, all_calls {
                refusal, _ if refusal != "" -> stream_types.Refused(refusal)
                _, [] -> stream_types.CompletedText(all_text)
                _, _ ->
                  stream_types.CompletedToolCalls(
                    all_text,
                    all_calls,
                    Some(completed.id),
                    [],
                  )
              }
              stream_types.StreamFinished(
                outcome: outcome,
                usage: completed.usage,
              )
            }
            "incomplete" -> {
              let outcome = stream_types.OutputLimited(all_text, all_calls)
              stream_types.StreamFinished(
                outcome: outcome,
                usage: completed.usage,
              )
            }
            "failed" -> {
              let #(code, reason) = response_error(data)
              stream_types.StreamFailed(
                error: error.Provider(code:, message: reason),
                retry: retry_evidence,
              )
            }
            "cancelled" ->
              stream_types.StreamFailed(
                error: error.Provider(
                  code: Some("cancelled"),
                  message: "Provider cancelled the response",
                ),
                retry: retry_evidence,
              )
            other -> {
              stream_types.StreamFailed(
                error: error.Provider(
                  code: None,
                  message: "Unknown response status: " <> other,
                ),
                retry: retry_evidence,
              )
            }
          }

          let progress = case completed.usage {
            Some(u) -> [message.UsageUpdate(u)]
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
) -> Result(#(Reducer, List(message.Progress)), error.Error) {
  case json.parse(data, decode_error_payload()) {
    Error(_) -> Error(error.Protocol("Malformed error event payload"))
    Ok(err) -> {
      let retry_evidence =
        stream_types.RetryEvidence(
          classification: stream_types.RequestMayHaveReachedProvider,
          response_bytes_observed: reducer.response_bytes_observed,
          semantic_progress_observed: reducer.semantic_progress_observed,
        )
      let terminal =
        stream_types.StreamFailed(
          error: error.Provider(code: err.code, message: err.message),
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
) -> Result(String, error.Error) {
  case maybe_item_id, maybe_output_index {
    Some(id), Some(idx) ->
      case dict.get(reducer.index_to_item_id, idx) {
        Ok(mapped_id) if mapped_id == id -> Ok(id)
        Ok(_) ->
          Error(error.Protocol(
            "Contradictory item_id and output_index: item_id="
            <> id
            <> ", index="
            <> int.to_string(idx),
          ))
        Error(Nil) ->
          Error(error.Protocol(
            "Unmapped output_index in delta: " <> int.to_string(idx),
          ))
      }
    Some(id), None -> Ok(id)
    None, Some(idx) ->
      case dict.get(reducer.index_to_item_id, idx) {
        Ok(id) -> Ok(id)
        Error(Nil) ->
          Error(error.Protocol(
            "Unmapped output_index in delta: " <> int.to_string(idx),
          ))
      }
    None, None ->
      Error(error.Protocol("Event missing item_id and output_index"))
  }
}

fn check_all_text_completed(
  text_done: Dict(String, Bool),
  text_order: List(String),
) -> Result(Nil, error.Error) {
  list.fold(text_order, Ok(Nil), fn(acc, id) {
    case acc {
      Error(e) -> Error(e)
      Ok(Nil) ->
        case dict.get(text_done, id) {
          Ok(True) -> Ok(Nil)
          _ ->
            Error(error.Protocol(
              "Text block still incomplete at completion: " <> id,
            ))
        }
    }
  })
}

fn check_all_tools_completed(
  tools: Dict(String, ToolBuffer),
) -> Result(Nil, error.Error) {
  dict.fold(tools, Ok(Nil), fn(acc, id, tool) {
    case acc {
      Error(e) -> Error(e)
      Ok(Nil) ->
        case tool.is_done {
          True -> Ok(Nil)
          False ->
            Error(error.Protocol(
              "Tool call still incomplete at completion: " <> id,
            ))
        }
    }
  })
}

fn check_all_reasoning_completed(
  reasoning_done: Dict(String, Bool),
  reasoning_order: List(String),
) -> Result(Nil, error.Error) {
  list.fold(reasoning_order, Ok(Nil), fn(acc, id) {
    case acc {
      Error(e) -> Error(e)
      Ok(Nil) ->
        case dict.get(reasoning_done, id) {
          Ok(True) -> Ok(Nil)
          _ ->
            Error(error.Protocol(
              "Reasoning block still incomplete at completion: " <> id,
            ))
        }
    }
  })
}
