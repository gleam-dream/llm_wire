//// Test-only application composition. Production callers own their histories.

import gleam/list
import llm_wire
import llm_wire/message

/// Append a turn and one result per `#(call_id, content)`.
pub fn append_results(
  source: llm_wire.Request(o),
  turn: message.AssistantTurn,
  results: List(#(String, String)),
) -> llm_wire.Request(o) {
  llm_wire.append(source, [
    message.Assistant(turn),
    ..list.map(results, fn(result) { message.ToolResult(result.0, result.1) })
  ])
}
