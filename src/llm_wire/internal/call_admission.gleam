import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm_wire/types

/// Admits a completed tool-call batch. Duplicate IDs and byte bounds always
/// fail the response. An undeclared tool or invalid arguments fail it under
/// `RejectInvalidToolCalls` and become per-call issues under
/// `ReportInvalidToolCalls`; every call stays in provider order either way.
pub fn admit(
  calls: List(types.ToolCall),
  tools: List(types.ToolDefinition),
  limits: types.Limits,
  checks: types.ToolCallChecks,
) -> Result(List(types.ToolCallIssue), types.WireError) {
  use Nil <- result.try(case calls {
    [] -> Error(types.ProtocolError("Empty tool-call batch"))
    _ -> Ok(Nil)
  })
  let count = list.length(calls)
  use Nil <- result.try(case count > limits.active_blocks_limit {
    True ->
      Error(types.ResourceLimitExceeded(
        "active_blocks_limit",
        limits.active_blocks_limit,
        count,
      ))
    False -> Ok(Nil)
  })
  let empty: Result(
    #(List(types.CallId), Int, List(types.ToolCallIssue)),
    types.WireError,
  ) = Ok(#([], 0, []))
  use #(_, _, issues) <- result.try(
    list.fold(calls, empty, fn(acc, call) {
      use #(seen, bytes, issues) <- result.try(acc)
      use Nil <- result.try(case list.contains(seen, call.id) {
        True -> Error(types.ProtocolError("Duplicate tool call ID"))
        False -> Ok(Nil)
      })
      let max_bytes = limits.argument_bytes_per_call_limit
      use Nil <- result.try(types.check_argument_bytes(
        max_bytes,
        call.arguments_json,
      ))
      let total = bytes + string.byte_size(call.arguments_json)
      use Nil <- result.try(case total > limits.total_argument_bytes_limit {
        True ->
          Error(types.ResourceLimitExceeded(
            "total_argument_bytes_limit",
            limits.total_argument_bytes_limit,
            total,
          ))
        False -> Ok(Nil)
      })
      let issue = case
        list.find(tools, fn(tool) { types.tool_name_of(tool) == call.name })
      {
        Error(Nil) -> Some(types.UnknownTool(call.id))
        Ok(tool) ->
          case
            types.check_tool_arguments(tool, max_bytes, call.arguments_json)
          {
            Ok(Nil) -> None
            Error(reason) -> Some(types.InvalidArguments(call.id, reason))
          }
      }
      use issues <- result.try(case issue, checks {
        None, _ -> Ok(issues)
        Some(issue), types.ReportInvalidToolCalls -> Ok([issue, ..issues])
        Some(types.UnknownTool(_)), types.RejectInvalidToolCalls ->
          Error(types.ProtocolError(
            "Tool not declared in admitted catalog: "
            <> types.tool_name_to_string(call.name),
          ))
        Some(types.InvalidArguments(_, reason)), types.RejectInvalidToolCalls ->
          Error(types.ProtocolError(reason))
      })
      Ok(#([call.id, ..seen], total, issues))
    }),
  )
  Ok(list.reverse(issues))
}

pub fn validate_text(
  limits: types.Limits,
  text: String,
) -> Result(Nil, types.WireError) {
  let size = string.byte_size(text)
  case size > limits.total_text_bytes_limit {
    True ->
      Error(types.ResourceLimitExceeded(
        "total_text_bytes_limit",
        limits.total_text_bytes_limit,
        size,
      ))
    False -> Ok(Nil)
  }
}

pub fn validate_metadata(
  limits: types.Limits,
  calls: List(types.ToolCall),
  response_id: Option(String),
  provider_data: Option(String),
) -> Result(Nil, types.WireError) {
  let response_bytes = case response_id {
    Some(id) -> string.byte_size(id)
    None -> 0
  }
  let bytes =
    list.fold(
      calls,
      response_bytes + option_string_bytes(provider_data),
      fn(total, call) {
        total
        + string.byte_size(types.call_id_to_string(call.id))
        + string.byte_size(types.tool_name_to_string(call.name))
        + option_string_bytes(call.provider_id)
        + option_string_bytes(call.provider_state)
      },
    )
  case bytes > limits.provider_metadata_bytes_limit {
    True ->
      Error(types.ResourceLimitExceeded(
        "provider_metadata_bytes_limit",
        limits.provider_metadata_bytes_limit,
        bytes,
      ))
    False -> Ok(Nil)
  }
}

fn option_string_bytes(value: Option(String)) -> Int {
  case value {
    Some(text) -> string.byte_size(text)
    None -> 0
  }
}
