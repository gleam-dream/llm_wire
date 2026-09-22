import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm_wire/sse
import llm_wire/types

pub opaque type Reducer {
  Reducer(
    limits: types.Limits,
    input_tokens: Int,
    output_tokens: Int,
    has_usage: Bool,
    stop_reason: Option(String),
    response_id: Option(String),
    blocks: Dict(Int, BlockState),
    block_order: List(Int),
    active_blocks_count: Int,
    total_text_bytes: Int,
    total_argument_bytes: Int,
    response_bytes_observed: Bool,
    semantic_progress_observed: Bool,
    server_tool_observed: Bool,
    terminal_outcome: Option(types.TerminalOutcome),
    admitted_tools: List(types.ToolDefinition),
    seen_call_ids: List(String),
  )
}

type BlockState {
  TextBlock(text: String, is_closed: Bool)
  ToolUseBlock(
    call_id: types.CallId,
    name: types.ToolName,
    arguments: String,
    is_closed: Bool,
  )
  ServerToolBlock(is_closed: Bool)
}

pub fn new(limits: types.Limits) -> Reducer {
  Reducer(
    limits: limits,
    input_tokens: 0,
    output_tokens: 0,
    has_usage: False,
    stop_reason: None,
    response_id: None,
    blocks: dict.new(),
    block_order: [],
    active_blocks_count: 0,
    total_text_bytes: 0,
    total_argument_bytes: 0,
    response_bytes_observed: False,
    semantic_progress_observed: False,
    server_tool_observed: False,
    terminal_outcome: None,
    admitted_tools: [],
    seen_call_ids: [],
  )
}

pub fn new_with_tools(
  limits: types.Limits,
  tools: List(types.ToolDefinition),
) -> Result(Reducer, types.WireError) {
  case types.admit_tool_catalog(tools) {
    Error(error) -> Error(error)
    Ok(admitted) -> Ok(Reducer(..new(limits), admitted_tools: admitted))
  }
}

pub fn server_tool_observed(reducer: Reducer) -> Bool {
  reducer.server_tool_observed
}

pub fn semantic_progress_observed(reducer: Reducer) -> Bool {
  reducer.semantic_progress_observed
}

pub fn retry_evidence(
  reducer: Reducer,
  fallback_classification: types.RetryClassification,
) -> types.RetryEvidence {
  let classification = case reducer.server_tool_observed {
    True -> types.EffectUnknown
    False -> fallback_classification
  }
  types.RetryEvidence(
    classification: classification,
    response_bytes_observed: reducer.response_bytes_observed,
    semantic_progress_observed: reducer.semantic_progress_observed,
  )
}

pub fn terminal(reducer: Reducer) -> Option(types.TerminalOutcome) {
  reducer.terminal_outcome
}

pub fn step(
  reducer: Reducer,
  event: sse.ServerSentEvent,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case reducer.terminal_outcome {
    Some(_) ->
      Error(types.ProtocolError("Event received after stream terminal"))
    None -> {
      let with_bytes = Reducer(..reducer, response_bytes_observed: True)
      case event.event {
        Some("message_start") -> handle_message_start(with_bytes, event.data)

        Some("content_block_start") ->
          handle_content_block_start(with_bytes, event.data)

        Some("content_block_delta") ->
          handle_content_block_delta(with_bytes, event.data)

        Some("content_block_stop") ->
          handle_content_block_stop(with_bytes, event.data)

        Some("message_delta") -> handle_message_delta(with_bytes, event.data)

        Some("message_stop") -> handle_message_stop(with_bytes, event.data)

        Some("ping") -> Ok(#(with_bytes, []))

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
                    provider: "anthropic",
                    event_name: other_event,
                  ),
                ]),
              )
          }
        }

        None -> Ok(#(with_bytes, []))
      }
    }
  }
}

type MessageStartPayload {
  MessageStartPayload(id: Option(String), input_tokens: Int, output_tokens: Int)
}

fn decode_message_start() -> decode.Decoder(MessageStartPayload) {
  use id <- decode.optional_field(
    "message",
    None,
    decode.optional_field("id", None, decode.optional(decode.string), fn(value) {
      decode.success(value)
    }),
  )
  use in_tok <- decode.subfield(
    ["message", "usage", "input_tokens"],
    decode.int,
  )
  use out_tok <- decode.optional_field(
    "message",
    0,
    decode.optional_field(
      "usage",
      0,
      decode.optional_field("output_tokens", 0, decode.int, fn(o) {
        decode.success(o)
      }),
      fn(u) { decode.success(u) },
    ),
  )
  decode.success(MessageStartPayload(id, in_tok, out_tok))
}

fn handle_message_start(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case json.parse(data, decode_message_start()) {
    Error(_) -> Error(types.ProtocolError("Malformed message_start payload"))
    Ok(payload) -> {
      Ok(
        #(
          Reducer(
            ..reducer,
            input_tokens: payload.input_tokens,
            output_tokens: payload.output_tokens,
            has_usage: True,
            response_id: payload.id,
          ),
          [],
        ),
      )
    }
  }
}

type ContentBlockStartPayload {
  ContentBlockStartPayload(
    index: Int,
    block_type: String,
    id: Option(String),
    name: Option(String),
  )
}

fn decode_content_block_start() -> decode.Decoder(ContentBlockStartPayload) {
  use index <- decode.field("index", decode.int)
  use block_type <- decode.subfield(["content_block", "type"], decode.string)
  use id <- decode.optional_field(
    "content_block",
    None,
    decode.optional_field("id", None, decode.optional(decode.string), fn(i) {
      decode.success(i)
    }),
  )
  use name <- decode.optional_field(
    "content_block",
    None,
    decode.optional_field("name", None, decode.optional(decode.string), fn(n) {
      decode.success(n)
    }),
  )
  decode.success(ContentBlockStartPayload(index, block_type, id, name))
}

fn handle_content_block_start(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case json.parse(data, decode_content_block_start()) {
    Error(_) ->
      Error(types.ProtocolError("Malformed content_block_start payload"))
    Ok(payload) -> {
      case reducer.active_blocks_count >= reducer.limits.active_blocks_limit {
        True ->
          Error(types.ResourceLimitExceeded(
            "active_blocks_limit",
            reducer.limits.active_blocks_limit,
            reducer.active_blocks_count + 1,
          ))
        False -> {
          case dict.has_key(reducer.blocks, payload.index) {
            True ->
              Error(types.ProtocolError(
                "Duplicate content block index: "
                <> string.inspect(payload.index),
              ))
            False -> {
              let updated_order =
                list.append(reducer.block_order, [payload.index])
              case payload.block_type {
                "text" -> {
                  let updated_blocks =
                    dict.insert(
                      reducer.blocks,
                      payload.index,
                      TextBlock("", False),
                    )
                  Ok(
                    #(
                      Reducer(
                        ..reducer,
                        blocks: updated_blocks,
                        block_order: updated_order,
                        active_blocks_count: reducer.active_blocks_count + 1,
                      ),
                      [],
                    ),
                  )
                }
                "tool_use" -> {
                  case payload.id, payload.name {
                    Some(id_str), Some(name_str) -> {
                      case list.contains(reducer.seen_call_ids, id_str) {
                        True ->
                          Error(types.ProtocolError(
                            "Duplicate tool call id: " <> id_str,
                          ))
                        False -> {
                          case
                            list.any(reducer.admitted_tools, fn(tool) {
                              types.tool_definition_name(tool) == name_str
                            })
                          {
                            False ->
                              Error(types.ProtocolError(
                                "Tool call for unadmitted tool: " <> name_str,
                              ))
                            True -> {
                              case
                                types.call_id(id_str),
                                types.tool_name(name_str)
                              {
                                Ok(call_id), Ok(tool_name) -> {
                                  let updated_blocks =
                                    dict.insert(
                                      reducer.blocks,
                                      payload.index,
                                      ToolUseBlock(
                                        call_id,
                                        tool_name,
                                        "",
                                        False,
                                      ),
                                    )
                                  let updated_seen_calls = [
                                    id_str,
                                    ..reducer.seen_call_ids
                                  ]
                                  Ok(
                                    #(
                                      Reducer(
                                        ..reducer,
                                        blocks: updated_blocks,
                                        block_order: updated_order,
                                        seen_call_ids: updated_seen_calls,
                                        active_blocks_count: reducer.active_blocks_count
                                          + 1,
                                      ),
                                      [],
                                    ),
                                  )
                                }
                                _, _ ->
                                  Error(types.ProtocolError(
                                    "Invalid call_id or tool_name in tool_use block",
                                  ))
                              }
                            }
                          }
                        }
                      }
                    }
                    _, _ ->
                      Error(types.ProtocolError(
                        "tool_use content block missing id or name",
                      ))
                  }
                }
                "server_tool_use" -> {
                  let updated_blocks =
                    dict.insert(
                      reducer.blocks,
                      payload.index,
                      ServerToolBlock(False),
                    )
                  Ok(
                    #(
                      Reducer(
                        ..reducer,
                        blocks: updated_blocks,
                        block_order: updated_order,
                        active_blocks_count: reducer.active_blocks_count + 1,
                        server_tool_observed: True,
                      ),
                      [],
                    ),
                  )
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

type ContentBlockDeltaPayload {
  ContentBlockDeltaPayload(
    index: Int,
    delta_type: String,
    text: Option(String),
    thinking: Option(String),
    partial_json: Option(String),
  )
}

fn decode_content_block_delta() -> decode.Decoder(ContentBlockDeltaPayload) {
  use index <- decode.field("index", decode.int)
  use delta_type <- decode.subfield(["delta", "type"], decode.string)
  use text <- decode.optional_field(
    "delta",
    None,
    decode.optional_field("text", None, decode.optional(decode.string), fn(t) {
      decode.success(t)
    }),
  )
  use thinking <- decode.optional_field(
    "delta",
    None,
    decode.optional_field(
      "thinking",
      None,
      decode.optional(decode.string),
      fn(th) { decode.success(th) },
    ),
  )
  use partial_json <- decode.optional_field(
    "delta",
    None,
    decode.optional_field(
      "partial_json",
      None,
      decode.optional(decode.string),
      fn(pj) { decode.success(pj) },
    ),
  )
  decode.success(ContentBlockDeltaPayload(
    index,
    delta_type,
    text,
    thinking,
    partial_json,
  ))
}

fn handle_content_block_delta(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case json.parse(data, decode_content_block_delta()) {
    Error(_) ->
      Error(types.ProtocolError("Malformed content_block_delta payload"))
    Ok(payload) -> {
      case dict.get(reducer.blocks, payload.index) {
        Error(Nil) ->
          Error(types.ProtocolError(
            "Unknown content block index: " <> string.inspect(payload.index),
          ))
        Ok(block) -> {
          case block {
            TextBlock(existing, is_closed) -> {
              case is_closed {
                True ->
                  Error(types.ProtocolError(
                    "Delta received after content_block_stop",
                  ))
                False -> {
                  case payload.delta_type {
                    "text_delta" | "thinking_delta" -> {
                      let fragment = case payload.text {
                        Some(t) -> t
                        None ->
                          case payload.thinking {
                            Some(th) -> th
                            None -> ""
                          }
                      }
                      let frag_bytes = string.byte_size(fragment)
                      let block_bytes = string.byte_size(existing) + frag_bytes
                      let total_bytes = reducer.total_text_bytes + frag_bytes

                      case
                        block_bytes > reducer.limits.text_bytes_per_block_limit
                      {
                        True ->
                          Error(types.ResourceLimitExceeded(
                            "text_bytes_per_block_limit",
                            reducer.limits.text_bytes_per_block_limit,
                            block_bytes,
                          ))
                        False ->
                          case
                            total_bytes > reducer.limits.total_text_bytes_limit
                          {
                            True ->
                              Error(types.ResourceLimitExceeded(
                                "total_text_bytes_limit",
                                reducer.limits.total_text_bytes_limit,
                                total_bytes,
                              ))
                            False -> {
                              let updated_block =
                                TextBlock(existing <> fragment, False)
                              let updated_blocks =
                                dict.insert(
                                  reducer.blocks,
                                  payload.index,
                                  updated_block,
                                )
                              let progress = case payload.delta_type {
                                "thinking_delta" -> [
                                  types.ReasoningDelta(
                                    block_id: string.inspect(payload.index),
                                    text: fragment,
                                  ),
                                ]
                                _ -> [
                                  types.TextDelta(
                                    block_id: string.inspect(payload.index),
                                    text: fragment,
                                  ),
                                ]
                              }
                              Ok(#(
                                Reducer(
                                  ..reducer,
                                  blocks: updated_blocks,
                                  total_text_bytes: total_bytes,
                                  semantic_progress_observed: True,
                                ),
                                progress,
                              ))
                            }
                          }
                      }
                    }
                    other ->
                      Error(types.ProtocolError(
                        "Delta type mismatch for text block: " <> other,
                      ))
                  }
                }
              }
            }
            ToolUseBlock(call_id, name, existing_args, is_closed) -> {
              case is_closed {
                True ->
                  Error(types.ProtocolError(
                    "Delta received after content_block_stop",
                  ))
                False -> {
                  case payload.delta_type {
                    "input_json_delta" -> {
                      let fragment = case payload.partial_json {
                        Some(pj) -> pj
                        None -> ""
                      }
                      let frag_bytes = string.byte_size(fragment)
                      let tool_bytes =
                        string.byte_size(existing_args) + frag_bytes
                      let total_bytes =
                        reducer.total_argument_bytes + frag_bytes

                      case
                        tool_bytes
                        > reducer.limits.argument_bytes_per_call_limit
                      {
                        True ->
                          Error(types.ResourceLimitExceeded(
                            "argument_bytes_per_call_limit",
                            reducer.limits.argument_bytes_per_call_limit,
                            tool_bytes,
                          ))
                        False ->
                          case
                            total_bytes
                            > reducer.limits.total_argument_bytes_limit
                          {
                            True ->
                              Error(types.ResourceLimitExceeded(
                                "total_argument_bytes_limit",
                                reducer.limits.total_argument_bytes_limit,
                                total_bytes,
                              ))
                            False -> {
                              let updated_block =
                                ToolUseBlock(
                                  call_id,
                                  name,
                                  existing_args <> fragment,
                                  False,
                                )
                              let updated_blocks =
                                dict.insert(
                                  reducer.blocks,
                                  payload.index,
                                  updated_block,
                                )
                              Ok(
                                #(
                                  Reducer(
                                    ..reducer,
                                    blocks: updated_blocks,
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
                    other ->
                      Error(types.ProtocolError(
                        "Delta type mismatch for tool_use block: " <> other,
                      ))
                  }
                }
              }
            }
            ServerToolBlock(is_closed) -> {
              case is_closed {
                True ->
                  Error(types.ProtocolError(
                    "Delta received after content_block_stop",
                  ))
                False -> Ok(#(reducer, []))
              }
            }
          }
        }
      }
    }
  }
}

type ContentBlockStopPayload {
  ContentBlockStopPayload(index: Int)
}

fn decode_content_block_stop() -> decode.Decoder(ContentBlockStopPayload) {
  use index <- decode.field("index", decode.int)
  decode.success(ContentBlockStopPayload(index))
}

fn handle_content_block_stop(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case json.parse(data, decode_content_block_stop()) {
    Error(_) ->
      Error(types.ProtocolError("Malformed content_block_stop payload"))
    Ok(payload) -> {
      case dict.get(reducer.blocks, payload.index) {
        Error(Nil) ->
          Error(types.ProtocolError(
            "Unknown content block index: " <> string.inspect(payload.index),
          ))
        Ok(block) -> {
          case block {
            TextBlock(text, is_closed) -> {
              case is_closed {
                True ->
                  Error(types.ProtocolError("Duplicate content_block_stop"))
                False -> {
                  let updated_blocks =
                    dict.insert(
                      reducer.blocks,
                      payload.index,
                      TextBlock(text, True),
                    )
                  Ok(#(Reducer(..reducer, blocks: updated_blocks), []))
                }
              }
            }
            ToolUseBlock(call_id, name, args, is_closed) -> {
              case is_closed {
                True ->
                  Error(types.ProtocolError("Duplicate content_block_stop"))
                False -> {
                  let tool_nm = types.tool_name_to_string(name)
                  case
                    list.find(reducer.admitted_tools, fn(definition) {
                      types.tool_definition_name(definition) == tool_nm
                    })
                  {
                    Ok(admitted) -> {
                      use Nil <- result.try(types.validate_tool_arguments(
                        admitted,
                        reducer.limits.argument_bytes_per_call_limit,
                        args,
                      ))
                      let updated_blocks =
                        dict.insert(
                          reducer.blocks,
                          payload.index,
                          ToolUseBlock(call_id, name, args, True),
                        )
                      Ok(
                        #(
                          Reducer(
                            ..reducer,
                            blocks: updated_blocks,
                            semantic_progress_observed: True,
                          ),
                          [],
                        ),
                      )
                    }
                    Error(Nil) ->
                      Error(types.ProtocolError(
                        "Tool call for unadmitted tool: " <> tool_nm,
                      ))
                  }
                }
              }
            }
            ServerToolBlock(is_closed) -> {
              case is_closed {
                True ->
                  Error(types.ProtocolError("Duplicate content_block_stop"))
                False -> {
                  let updated_blocks =
                    dict.insert(
                      reducer.blocks,
                      payload.index,
                      ServerToolBlock(True),
                    )
                  Ok(#(Reducer(..reducer, blocks: updated_blocks), []))
                }
              }
            }
          }
        }
      }
    }
  }
}

type MessageDeltaPayload {
  MessageDeltaPayload(stop_reason: Option(String), output_tokens: Option(Int))
}

fn decode_message_delta() -> decode.Decoder(MessageDeltaPayload) {
  use stop_reason <- decode.optional_field(
    "delta",
    None,
    decode.optional_field(
      "stop_reason",
      None,
      decode.optional(decode.string),
      fn(sr) { decode.success(sr) },
    ),
  )
  use output_tokens <- decode.optional_field(
    "usage",
    None,
    decode.optional_field(
      "output_tokens",
      None,
      decode.optional(decode.int),
      fn(ot) { decode.success(ot) },
    ),
  )
  decode.success(MessageDeltaPayload(stop_reason, output_tokens))
}

fn handle_message_delta(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case json.parse(data, decode_message_delta()) {
    Error(_) -> Error(types.ProtocolError("Malformed message_delta payload"))
    Ok(payload) -> {
      let updated_stop_reason = case payload.stop_reason {
        Some(sr) -> Some(sr)
        None -> reducer.stop_reason
      }
      let #(updated_out_tokens, progress) = case payload.output_tokens {
        Some(ot) -> {
          let tot = reducer.input_tokens + ot
          let usage =
            types.Usage(
              input_tokens: reducer.input_tokens,
              output_tokens: ot,
              total_tokens: tot,
            )
          #(ot, [types.UsageUpdate(usage)])
        }
        None -> #(reducer.output_tokens, [])
      }

      Ok(#(
        Reducer(
          ..reducer,
          stop_reason: updated_stop_reason,
          output_tokens: updated_out_tokens,
          semantic_progress_observed: True,
        ),
        progress,
      ))
    }
  }
}

fn handle_message_stop(
  reducer: Reducer,
  _data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  // Check that all blocks are closed
  case check_all_blocks_closed(reducer.blocks) {
    Error(err) -> Error(err)
    Ok(Nil) -> {
      let all_text =
        list.filter_map(reducer.block_order, fn(idx) {
          case dict.get(reducer.blocks, idx) {
            Ok(TextBlock(t, _)) -> Ok(t)
            _ -> Error(Nil)
          }
        })
        |> string.join("")

      let all_calls =
        list.filter_map(reducer.block_order, fn(idx) {
          case dict.get(reducer.blocks, idx) {
            Ok(ToolUseBlock(cid, name, args, _)) ->
              Ok(types.ToolCall(
                id: cid,
                name: name,
                arguments_json: args,
                provider_id: Some(types.call_id_to_string(cid)),
                provider_state: None,
              ))
            _ -> Error(Nil)
          }
        })

      let final_usage = case reducer.has_usage {
        True ->
          Some(types.Usage(
            input_tokens: reducer.input_tokens,
            output_tokens: reducer.output_tokens,
            total_tokens: reducer.input_tokens + reducer.output_tokens,
          ))
        False -> None
      }

      let retry_evidence =
        retry_evidence(reducer, types.RequestMayHaveReachedProvider)
      let terminal = case reducer.stop_reason {
        Some("max_tokens") ->
          types.StreamFinished(
            types.OutputLimited(all_text, all_calls),
            final_usage,
          )
        Some("tool_use") ->
          types.StreamFinished(
            types.CompletedToolCalls(all_text, all_calls, reducer.response_id),
            final_usage,
          )
        Some("refusal") ->
          types.StreamFinished(types.Refused(all_text), final_usage)
        Some("end_turn") ->
          case all_calls {
            [] ->
              types.StreamFinished(types.CompletedText(all_text), final_usage)
            _ ->
              types.StreamFailed(
                types.ProviderError(
                  code: Some("end_turn"),
                  message: "Tool calls ended without the provider tool_use stop reason",
                ),
                retry_evidence,
              )
          }
        Some("pause_turn") ->
          types.StreamFailed(
            types.ProviderError(
              code: Some("pause_turn"),
              message: "Provider paused for a hosted effect outside the application tool contract",
            ),
            retry_evidence,
          )
        Some(other) ->
          types.StreamFailed(
            types.ProviderError(
              code: Some(other),
              message: "Unsupported Anthropic stop reason: " <> other,
            ),
            retry_evidence,
          )
        None ->
          types.StreamFailed(
            types.ProviderError(
              code: None,
              message: "Anthropic message_stop arrived without a stop reason",
            ),
            retry_evidence,
          )
      }

      Ok(
        #(
          Reducer(
            ..reducer,
            terminal_outcome: Some(terminal),
            semantic_progress_observed: True,
          ),
          [],
        ),
      )
    }
  }
}

type ErrorPayload {
  ErrorPayload(error_type: String, message: String)
}

fn decode_error_payload() -> decode.Decoder(ErrorPayload) {
  use error_type <- decode.subfield(["error", "type"], decode.string)
  use message <- decode.subfield(["error", "message"], decode.string)
  decode.success(ErrorPayload(error_type, message))
}

fn handle_error_event(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case json.parse(data, decode_error_payload()) {
    Error(_) -> Error(types.ProtocolError("Malformed error event payload"))
    Ok(err) -> {
      let classification = case reducer.server_tool_observed {
        True -> types.EffectUnknown
        False -> types.RequestMayHaveReachedProvider
      }
      let retry_evidence =
        types.RetryEvidence(
          classification: classification,
          response_bytes_observed: reducer.response_bytes_observed,
          semantic_progress_observed: reducer.semantic_progress_observed,
        )
      let terminal =
        types.StreamFailed(
          error: types.ProviderError(
            code: Some(err.error_type),
            message: err.message,
          ),
          retry: retry_evidence,
        )
      Ok(#(Reducer(..reducer, terminal_outcome: Some(terminal)), []))
    }
  }
}

fn check_all_blocks_closed(
  blocks: Dict(Int, BlockState),
) -> Result(Nil, types.WireError) {
  dict.fold(blocks, Ok(Nil), fn(acc, idx, block) {
    case acc {
      Error(e) -> Error(e)
      Ok(Nil) -> {
        let is_closed = case block {
          TextBlock(_, closed) -> closed
          ToolUseBlock(_, _, _, closed) -> closed
          ServerToolBlock(closed) -> closed
        }
        case is_closed {
          True -> Ok(Nil)
          False ->
            Error(types.ProtocolError(
              "Content block incomplete at message_stop: index "
              <> string.inspect(idx),
            ))
        }
      }
    }
  })
}
