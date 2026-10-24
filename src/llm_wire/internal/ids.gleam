import gleam/string
import llm_wire/error
import llm_wire/internal/tool_def

/// A provider-returned call id: trimmed and non-empty.
pub fn call_id(raw: String) -> Result(String, error.Error) {
  case string.trim(raw) {
    "" -> Error(error.Protocol("call_id cannot be empty"))
    trimmed -> Ok(trimmed)
  }
}

/// A provider-returned tool name must follow the tool-name rule, so it can
/// be replayed.
pub fn provider_tool_name(raw: String) -> Result(String, error.Error) {
  case tool_def.check_name(raw) {
    Ok(Nil) -> Ok(raw)
    Error(_) ->
      Error(error.Protocol("Provider returned an invalid tool name: " <> raw))
  }
}
