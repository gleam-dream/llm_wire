import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/types

pub opaque type Reducer {
  Reducer(
    limits: types.Limits,
    admitted_tools: List(types.ToolDefinition),
    text_buffer: String,
    tool_buffers: Dict(String, ToolBuffer),
    tool_order: List(String),
    seen_call_ids: List(String),
    total_text_bytes: Int,
    total_argument_bytes: Int,
    response_bytes_observed: Bool,
    semantic_progress_observed: Bool,
    terminal_outcome: Option(stream_types.TerminalOutcome),
    response_id: Option(String),
    usage: Option(types.Usage),
    provider_parts: List(String),
    has_thought_signature: Bool,
  )
}

pub type ToolBuffer {
  ToolBuffer(
    call_id: types.CallId,
    provider_id: Option(String),
    name: types.ToolName,
    arguments: String,
    provider_state: Option(String),
  )
}

pub fn new(limits: types.Limits) -> Reducer {
  Reducer(
    limits: limits,
    admitted_tools: [],
    text_buffer: "",
    tool_buffers: dict.new(),
    tool_order: [],
    seen_call_ids: [],
    total_text_bytes: 0,
    total_argument_bytes: 0,
    response_bytes_observed: False,
    semantic_progress_observed: False,
    terminal_outcome: None,
    response_id: None,
    usage: None,
    provider_parts: [],
    has_thought_signature: False,
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

pub fn terminal(reducer: Reducer) -> Option(stream_types.TerminalOutcome) {
  reducer.terminal_outcome
}

pub fn retry_evidence(
  reducer: Reducer,
  fallback_classification: types.RetryClassification,
) -> types.RetryEvidence {
  let classification = case reducer.semantic_progress_observed {
    True ->
      case list.is_empty(reducer.tool_order) {
        False -> types.EffectUnknown
        True -> fallback_classification
      }
    False -> fallback_classification
  }
  types.RetryEvidence(
    classification: classification,
    response_bytes_observed: reducer.response_bytes_observed,
    semantic_progress_observed: reducer.semantic_progress_observed,
  )
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
      let data = string.trim(event.data)
      case data {
        "" -> Ok(#(with_bytes, []))
        _ -> handle_json_chunk(with_bytes, data)
      }
    }
  }
}

fn handle_json_chunk(
  reducer: Reducer,
  data: String,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case json.parse(data, decode.dynamic) {
    Error(_) -> Error(types.ProtocolError("Malformed Google response JSON"))
    Ok(json_val) -> process_google_payload(reducer, json_val)
  }
}

fn process_google_payload(
  reducer: Reducer,
  payload: Dynamic,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  // 1. Check for top-level error object: {"error": {"code": 400, "message": "...", "status": "..."}}
  case get_field(payload, "error") {
    Ok(error_obj) -> {
      let message =
        get_field(error_obj, "message")
        |> result.try(get_string)
        |> result.unwrap("Unknown Google API error")
      let status =
        get_field(error_obj, "status")
        |> result.try(get_string)
        |> option.from_result
      let evidence =
        retry_evidence(reducer, types.RequestMayHaveReachedProvider)
      let outcome =
        stream_types.StreamFailed(
          types.ProviderError(status, message),
          evidence,
        )
      Ok(#(Reducer(..reducer, terminal_outcome: Some(outcome)), []))
    }
    Error(Nil) -> {
      // 2. Check for promptFeedback block: {"promptFeedback": {"blockReason": "SAFETY"}}
      case get_field(payload, "promptFeedback") {
        Ok(feedback) ->
          case get_field(feedback, "blockReason") |> result.try(get_string) {
            Ok(reason) -> {
              let outcome =
                stream_types.StreamFinished(
                  stream_types.Refused(
                    "Prompt blocked by safety policy: " <> reason,
                  ),
                  reducer.usage,
                )
              Ok(#(Reducer(..reducer, terminal_outcome: Some(outcome)), []))
            }
            Error(Nil) -> process_candidates(reducer, payload)
          }
        Error(Nil) -> process_candidates(reducer, payload)
      }
    }
  }
}

fn process_candidates(
  reducer: Reducer,
  payload: Dynamic,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  let response_id =
    get_field(payload, "responseId")
    |> result.try(get_string)
    |> option.from_result
  let current_response_id = case response_id {
    Some(_) -> response_id
    None -> reducer.response_id
  }

  // Extract usage metadata if present
  let #(reducer_with_usage, usage_progress) = extract_usage(reducer, payload)

  // Extract candidates list
  case get_field(payload, "candidates") {
    Error(Nil) -> {
      // Chunk may contain only usage or metadata without candidates
      Ok(#(
        Reducer(..reducer_with_usage, response_id: current_response_id),
        usage_progress,
      ))
    }
    Ok(candidates_val) -> {
      use candidates <- result.try(case get_list(candidates_val) {
        Ok(items) -> Ok(items)
        Error(Nil) ->
          Error(types.ProtocolError("candidates field must be an array"))
      })

      case candidates {
        [] ->
          Ok(#(
            Reducer(..reducer_with_usage, response_id: current_response_id),
            usage_progress,
          ))
        [first_candidate, ..] -> {
          // Process parts of the primary candidate
          use #(reducer_after_parts, part_progress) <- result.try(
            process_candidate_content(reducer_with_usage, first_candidate),
          )

          // Process finishReason if present
          let finish_reason =
            get_field(first_candidate, "finishReason")
            |> result.try(get_string)
            |> option.from_result

          let final_reducer =
            Reducer(..reducer_after_parts, response_id: current_response_id)

          case finish_reason {
            None ->
              Ok(#(final_reducer, list.append(usage_progress, part_progress)))
            Some(reason) -> {
              use terminated_reducer <- result.try(apply_finish_reason(
                final_reducer,
                reason,
              ))
              Ok(#(
                terminated_reducer,
                list.append(usage_progress, part_progress),
              ))
            }
          }
        }
      }
    }
  }
}

fn extract_usage(
  reducer: Reducer,
  payload: Dynamic,
) -> #(Reducer, List(types.StreamProgress)) {
  case get_field(payload, "usageMetadata") {
    Error(Nil) -> #(reducer, [])
    Ok(meta) -> {
      case
        get_field(meta, "promptTokenCount") |> result.try(get_int),
        get_field(meta, "candidatesTokenCount") |> result.try(get_int),
        get_field(meta, "totalTokenCount") |> result.try(get_int)
      {
        Ok(prompt), Ok(candidates), Ok(total)
          if prompt >= 0 && candidates >= 0 && total >= 0
        -> {
          let usage = types.Usage(prompt, candidates, total)
          #(Reducer(..reducer, usage: Some(usage)), [types.UsageUpdate(usage)])
        }
        _, _, _ -> #(reducer, [])
      }
    }
  }
}

fn process_candidate_content(
  reducer: Reducer,
  candidate: Dynamic,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  case get_field(candidate, "content") {
    Error(Nil) -> Ok(#(reducer, []))
    Ok(content) -> {
      case get_field(content, "parts") {
        Error(Nil) -> Ok(#(reducer, []))
        Ok(parts_val) -> {
          use parts <- result.try(case get_list(parts_val) {
            Ok(items) -> Ok(items)
            Error(Nil) -> Error(types.ProtocolError("parts must be an array"))
          })
          list.fold(parts, Ok(#(reducer, [])), fn(acc, part) {
            use #(curr_reducer, curr_progress) <- result.try(acc)
            use #(next_reducer, new_progress) <- result.try(process_part(
              curr_reducer,
              part,
            ))
            Ok(#(next_reducer, list.append(curr_progress, new_progress)))
          })
        }
      }
    }
  }
}

fn process_part(
  reducer: Reducer,
  part: Dynamic,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  use thought_signature <- result.try(thought_signature(part))
  use encoded_part <- result.try(
    dynamic_json(part)
    |> result.replace_error(types.ProtocolError(
      "Gemini model part cannot be retained for continuation",
    )),
  )
  let with_provider_part =
    Reducer(
      ..reducer,
      provider_parts: [json.to_string(encoded_part), ..reducer.provider_parts],
      has_thought_signature: case thought_signature {
        Some(_) -> True
        None -> reducer.has_thought_signature
      },
    )
  case get_field(part, "functionCall") {
    Ok(function_call) ->
      process_function_call(
        with_provider_part,
        function_call,
        thought_signature,
      )
    Error(Nil) ->
      process_part_without_thought_signature(with_provider_part, part)
  }
}

fn thought_signature(part: Dynamic) -> Result(Option(String), types.WireError) {
  case get_field(part, "thoughtSignature") {
    Error(Nil) -> Ok(None)
    Ok(value) ->
      get_string(value)
      |> result.map(Some)
      |> result.replace_error(types.ProtocolError(
        "Gemini thoughtSignature must be a string",
      ))
  }
}

fn process_part_without_thought_signature(
  reducer: Reducer,
  part: Dynamic,
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  // Check for text
  case get_field(part, "text") {
    Ok(text_val) -> {
      use text <- result.try(case get_string(text_val) {
        Ok(t) -> Ok(t)
        Error(Nil) -> Error(types.ProtocolError("text part must be a string"))
      })
      let delta_bytes = string.byte_size(text)
      case delta_bytes > reducer.limits.text_bytes_per_block_limit {
        True ->
          Error(types.ResourceLimitExceeded(
            "text_bytes_per_block_limit",
            reducer.limits.text_bytes_per_block_limit,
            delta_bytes,
          ))
        False -> {
          let new_total = reducer.total_text_bytes + delta_bytes
          case new_total > reducer.limits.total_text_bytes_limit {
            True ->
              Error(types.ResourceLimitExceeded(
                "total_text_bytes_limit",
                reducer.limits.total_text_bytes_limit,
                new_total,
              ))
            False -> {
              let updated =
                Reducer(
                  ..reducer,
                  text_buffer: reducer.text_buffer <> text,
                  total_text_bytes: new_total,
                  semantic_progress_observed: True,
                )
              Ok(#(updated, [types.TextDelta(block_id: "0", text: text)]))
            }
          }
        }
      }
    }
    Error(Nil) -> {
      // Check for functionCall
      Ok(#(reducer, []))
    }
  }
}

fn process_function_call(
  reducer: Reducer,
  fc: Dynamic,
  provider_state: Option(String),
) -> Result(#(Reducer, List(types.StreamProgress)), types.WireError) {
  use name_str <- result.try(
    get_field(fc, "name")
    |> result.try(get_string)
    |> result.replace_error(types.ProtocolError("functionCall missing name")),
  )
  use tool_name <- result.try(types.provider_tool_name(name_str))

  let args_json = case get_field(fc, "args") {
    Ok(args_val) ->
      case dynamic_json(args_val) {
        Ok(encoded) -> json.to_string(encoded)
        Error(_) -> "{}"
      }
    Error(Nil) -> "{}"
  }

  let arg_bytes = string.byte_size(args_json)
  case arg_bytes > reducer.limits.argument_bytes_per_call_limit {
    True ->
      Error(types.ResourceLimitExceeded(
        "argument_bytes_per_call_limit",
        reducer.limits.argument_bytes_per_call_limit,
        arg_bytes,
      ))
    False -> {
      let new_total_args = reducer.total_argument_bytes + arg_bytes
      case new_total_args > reducer.limits.total_argument_bytes_limit {
        True ->
          Error(types.ResourceLimitExceeded(
            "total_argument_bytes_limit",
            reducer.limits.total_argument_bytes_limit,
            new_total_args,
          ))
        False -> {
          let call_count = list.length(reducer.tool_order)
          case call_count >= reducer.limits.active_blocks_limit {
            True ->
              Error(types.ResourceLimitExceeded(
                "active_blocks_limit",
                reducer.limits.active_blocks_limit,
                call_count + 1,
              ))
            False -> {
              // Preserve provider call ID if given, or synthesize a deterministic index ID
              let provider_id = case
                get_field(fc, "id") |> result.try(get_string)
              {
                Ok(id) if id != "" -> Some(id)
                _ -> None
              }
              let raw_id = case provider_id {
                Some(id) -> id
                None -> "call_" <> int.to_string(call_count)
              }
              case list.contains(reducer.seen_call_ids, raw_id) {
                True ->
                  Error(types.ProtocolError(
                    "Duplicate tool call id: " <> raw_id,
                  ))
                False -> {
                  use call_id <- result.try(types.call_id(raw_id))
                  let buffer =
                    ToolBuffer(
                      call_id,
                      provider_id,
                      tool_name,
                      args_json,
                      provider_state,
                    )
                  let updated_buffers =
                    dict.insert(reducer.tool_buffers, raw_id, buffer)
                  let updated_order = list.append(reducer.tool_order, [raw_id])
                  let updated_seen =
                    list.append(reducer.seen_call_ids, [raw_id])
                  let updated =
                    Reducer(
                      ..reducer,
                      tool_buffers: updated_buffers,
                      tool_order: updated_order,
                      seen_call_ids: updated_seen,
                      total_argument_bytes: new_total_args,
                      semantic_progress_observed: True,
                    )
                  // Do NOT emit executable ToolCall in progress!
                  Ok(#(updated, []))
                }
              }
            }
          }
        }
      }
    }
  }
}

fn apply_finish_reason(
  reducer: Reducer,
  reason: String,
) -> Result(Reducer, types.WireError) {
  let evidence = retry_evidence(reducer, types.RequestMayHaveReachedProvider)
  case reason {
    "STOP" -> {
      case reducer.tool_order {
        [] -> {
          let outcome =
            stream_types.StreamFinished(
              stream_types.CompletedText(reducer.text_buffer),
              reducer.usage,
            )
          Ok(Reducer(..reducer, terminal_outcome: Some(outcome)))
        }
        _ -> {
          // Validate every tool call against admitted tools
          use calls <- result.try(validate_and_build_tool_calls(reducer))
          let outcome = case reducer.has_thought_signature {
            True ->
              stream_types.StreamFinished(
                stream_types.CompletedToolCallsWithContinuation(
                  reducer.text_buffer,
                  calls,
                  reducer.response_id,
                  stream_types.GoogleProviderContinuation(list.reverse(
                    reducer.provider_parts,
                  )),
                ),
                reducer.usage,
              )
            False ->
              stream_types.StreamFinished(
                stream_types.CompletedToolCalls(
                  reducer.text_buffer,
                  calls,
                  reducer.response_id,
                ),
                reducer.usage,
              )
          }
          Ok(Reducer(..reducer, terminal_outcome: Some(outcome)))
        }
      }
    }
    "MAX_TOKENS" -> {
      let calls = build_unvalidated_tool_calls(reducer)
      let outcome =
        stream_types.StreamFinished(
          stream_types.OutputLimited(reducer.text_buffer, calls),
          reducer.usage,
        )
      Ok(Reducer(..reducer, terminal_outcome: Some(outcome)))
    }
    "SAFETY" -> {
      let outcome =
        stream_types.StreamFinished(
          stream_types.Refused("Google refused generation with reason: SAFETY"),
          reducer.usage,
        )
      Ok(Reducer(..reducer, terminal_outcome: Some(outcome)))
    }
    "RECITATION" -> {
      let outcome =
        stream_types.StreamFinished(
          stream_types.Refused(
            "Google refused generation with reason: RECITATION",
          ),
          reducer.usage,
        )
      Ok(Reducer(..reducer, terminal_outcome: Some(outcome)))
    }
    "BLOCKLIST" -> {
      let outcome =
        stream_types.StreamFinished(
          stream_types.Refused(
            "Google refused generation with reason: BLOCKLIST",
          ),
          reducer.usage,
        )
      Ok(Reducer(..reducer, terminal_outcome: Some(outcome)))
    }
    "PROHIBITED_CONTENT" -> {
      let outcome =
        stream_types.StreamFinished(
          stream_types.Refused(
            "Google refused generation with reason: PROHIBITED_CONTENT",
          ),
          reducer.usage,
        )
      Ok(Reducer(..reducer, terminal_outcome: Some(outcome)))
    }
    "SPII" -> {
      let outcome =
        stream_types.StreamFinished(
          stream_types.Refused("Google refused generation with reason: SPII"),
          reducer.usage,
        )
      Ok(Reducer(..reducer, terminal_outcome: Some(outcome)))
    }
    "OTHER" -> {
      let outcome =
        stream_types.StreamFailed(
          types.ProviderError(
            Some("OTHER"),
            "Google generation stopped with reason: OTHER",
          ),
          evidence,
        )
      Ok(Reducer(..reducer, terminal_outcome: Some(outcome)))
    }
    other -> {
      let outcome =
        stream_types.StreamFailed(
          types.ProviderError(
            Some(other),
            "Unknown Google finish reason: " <> other,
          ),
          evidence,
        )
      Ok(Reducer(..reducer, terminal_outcome: Some(outcome)))
    }
  }
}

fn validate_and_build_tool_calls(
  reducer: Reducer,
) -> Result(List(types.ToolCall), types.WireError) {
  let empty: Result(List(types.ToolCall), types.WireError) = Ok([])
  list.fold(reducer.tool_order, empty, fn(acc, raw_id) {
    use collected <- result.try(acc)
    case dict.get(reducer.tool_buffers, raw_id) {
      Error(Nil) ->
        Error(types.ProtocolError("Missing tool buffer for ID: " <> raw_id))
      Ok(buf) -> {
        let name_str = types.tool_name_to_string(buf.name)
        case
          list.find(reducer.admitted_tools, fn(tool) {
            types.tool_name_to_string(types.tool_name_of(tool)) == name_str
          })
        {
          Error(Nil) ->
            Error(types.ProtocolError(
              "Tool not declared in admitted catalog: " <> name_str,
            ))
          Ok(tool_def) -> {
            use Nil <- result.try(types.validate_tool_arguments(
              tool_def,
              reducer.limits.argument_bytes_per_call_limit,
              buf.arguments,
            ))
            let call =
              types.ToolCall(
                buf.call_id,
                buf.name,
                buf.arguments,
                buf.provider_id,
                buf.provider_state,
              )
            Ok(list.append(collected, [call]))
          }
        }
      }
    }
  })
}

fn build_unvalidated_tool_calls(reducer: Reducer) -> List(types.ToolCall) {
  list.filter_map(reducer.tool_order, fn(raw_id) {
    case dict.get(reducer.tool_buffers, raw_id) {
      Ok(buf) ->
        Ok(types.ToolCall(
          buf.call_id,
          buf.name,
          buf.arguments,
          buf.provider_id,
          buf.provider_state,
        ))
      Error(Nil) -> Error(Nil)
    }
  })
}

// Helpers for walking standard JSON dynamic values.

fn get_field(val: Dynamic, name: String) -> Result(Dynamic, Nil) {
  case decode.run(val, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) -> dict.get(fields, name)
    Error(_) -> Error(Nil)
  }
}

fn get_string(val: Dynamic) -> Result(String, Nil) {
  decode.run(val, decode.string)
  |> result.map_error(fn(_) { Nil })
}

fn get_int(val: Dynamic) -> Result(Int, Nil) {
  decode.run(val, decode.int)
  |> result.map_error(fn(_) { Nil })
}

fn get_list(val: Dynamic) -> Result(List(Dynamic), Nil) {
  decode.run(val, decode.list(decode.dynamic))
  |> result.map_error(fn(_) { Nil })
}

/// Re-encodes only a provider argument value using Gleam's ordinary JSON
/// constructors. This is adapter-local; the wire package exposes no generic
/// dynamic JSON codec.
fn dynamic_json(value: Dynamic) -> Result(json.Json, Nil) {
  case decode.run(value, decode.optional(decode.dynamic)) {
    Ok(None) -> Ok(json.null())
    Ok(Some(non_null)) -> {
      case decode.run(non_null, decode.string) {
        Ok(string_value) -> Ok(json.string(string_value))
        Error(_) ->
          case decode.run(non_null, decode.bool) {
            Ok(bool_value) -> Ok(json.bool(bool_value))
            Error(_) ->
              case decode.run(non_null, decode.int) {
                Ok(int_value) -> Ok(json.int(int_value))
                Error(_) ->
                  case decode.run(non_null, decode.float) {
                    Ok(float_value) -> Ok(json.float(float_value))
                    Error(_) ->
                      case decode.run(non_null, decode.list(decode.dynamic)) {
                        Ok(items) -> {
                          let empty: Result(List(json.Json), Nil) = Ok([])
                          use encoded <- result.try(
                            list.fold(items, empty, fn(acc, item) {
                              use values <- result.try(acc)
                              use encoded_item <- result.try(dynamic_json(item))
                              Ok(list.append(values, [encoded_item]))
                            }),
                          )
                          Ok(json.array(encoded, fn(item) { item }))
                        }
                        Error(_) ->
                          case
                            decode.run(
                              non_null,
                              decode.dict(decode.string, decode.dynamic),
                            )
                          {
                            Ok(fields) -> {
                              let empty: Result(List(#(String, json.Json)), Nil) =
                                Ok([])
                              use encoded <- result.try(
                                dict.to_list(fields)
                                |> list.fold(empty, fn(acc, entry) {
                                  use values <- result.try(acc)
                                  use encoded_value <- result.try(dynamic_json(
                                    entry.1,
                                  ))
                                  Ok(
                                    list.append(values, [
                                      #(entry.0, encoded_value),
                                    ]),
                                  )
                                }),
                              )
                              Ok(json.object(encoded))
                            }
                            Error(_) -> Error(Nil)
                          }
                      }
                  }
              }
          }
      }
    }
    Error(_) -> Error(Nil)
  }
}
