import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm_wire/error
import llm_wire/internal/limits
import llm_wire/internal/tool_def
import llm_wire/limit
import llm_wire/message
import llm_wire/tool

/// Admits a completed tool-call batch. Duplicate IDs and byte bounds always
/// fail the response. An undeclared tool or invalid arguments fail it under
/// `RejectInvalidToolCalls` and become per-call issues under
/// `ReportInvalidToolCalls`; every call stays in provider order either way.
pub fn admit(
  calls: List(message.ToolCall),
  tools: List(tool_def.Tool),
  limits: limits.Limits,
  checks: tool.ToolCallChecks,
) -> Result(List(tool.ToolCallIssue), error.Error) {
  use Nil <- result.try(case calls {
    [] -> Error(error.Protocol("Empty tool-call batch"))
    _ -> Ok(Nil)
  })
  let count = list.length(calls)
  use Nil <- result.try(case count > limits.active_blocks_limit {
    True ->
      Error(error.LimitExceeded(
        limit.ActiveBlocks,
        limits.active_blocks_limit,
        count,
      ))
    False -> Ok(Nil)
  })
  let empty: Result(#(List(String), Int, List(tool.ToolCallIssue)), error.Error) =
    Ok(#([], 0, []))
  use #(_, _, issues) <- result.try(
    list.fold(calls, empty, fn(acc, call) {
      use #(seen, bytes, issues) <- result.try(acc)
      use Nil <- result.try(case list.contains(seen, call.id) {
        True -> Error(error.Protocol("Duplicate tool call ID: " <> call.id))
        False -> Ok(Nil)
      })
      let max_bytes = limits.argument_bytes_per_call_limit
      let call_bytes = string.byte_size(call.arguments_json)
      use Nil <- result.try(case call_bytes > max_bytes {
        True ->
          Error(error.LimitExceeded(
            limit.ArgumentBytesPerCall,
            max_bytes,
            call_bytes,
          ))
        False -> Ok(Nil)
      })
      let total = bytes + string.byte_size(call.arguments_json)
      use Nil <- result.try(case total > limits.total_argument_bytes_limit {
        True ->
          Error(error.LimitExceeded(
            limit.TotalArgumentBytes,
            limits.total_argument_bytes_limit,
            total,
          ))
        False -> Ok(Nil)
      })
      let issue = case
        list.find(tools, fn(declared) { tool_def.name(declared) == call.name })
      {
        Error(Nil) -> Some(tool.UnknownTool(call.id))
        Ok(found) ->
          case tool_def.check_arguments(found, max_bytes, call.arguments_json) {
            Ok(Nil) -> None
            Error(reason) -> Some(tool.InvalidArguments(call.id, reason))
          }
      }
      use issues <- result.try(case issue, checks {
        None, _ -> Ok(issues)
        Some(issue), tool.ReportInvalidToolCalls -> Ok([issue, ..issues])
        Some(tool.UnknownTool(_)), tool.RejectInvalidToolCalls ->
          Error(error.Protocol(
            "Tool not declared in admitted catalog: " <> call.name,
          ))
        Some(tool.InvalidArguments(_, reason)), tool.RejectInvalidToolCalls ->
          Error(error.Protocol(
            "Tool call "
            <> call.name
            <> " has invalid arguments: "
            <> error.describe_value_failure(reason),
          ))
      })
      Ok(#([call.id, ..seen], total, issues))
    }),
  )
  Ok(list.reverse(issues))
}

pub fn validate_text(
  limits: limits.Limits,
  text: String,
) -> Result(Nil, error.Error) {
  let size = string.byte_size(text)
  case size > limits.total_text_bytes_limit {
    True ->
      Error(error.LimitExceeded(
        limit.TotalTextBytes,
        limits.total_text_bytes_limit,
        size,
      ))
    False -> Ok(Nil)
  }
}

pub fn validate_metadata(
  limits: limits.Limits,
  calls: List(message.ToolCall),
  response_id: Option(String),
  provider_data: Option(String),
) -> Result(Nil, error.Error) {
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
        + string.byte_size(call.id)
        + string.byte_size(call.name)
        + option_string_bytes(call.provider_id)
        + option_string_bytes(call.provider_state)
      },
    )
  case bytes > limits.provider_metadata_bytes_limit {
    True ->
      Error(error.LimitExceeded(
        limit.ProviderMetadataBytes,
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
