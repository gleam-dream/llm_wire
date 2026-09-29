//// Test-only application composition. Production callers own their histories.

import gleam/list
import llm_wire/types

pub fn append_results(
  source: types.Request,
  turn: types.AssistantTurn,
  results: List(types.ToolResult),
) -> types.Request {
  types.Request(
    ..source,
    messages: list.append(source.messages, [
      types.AssistantTurnMessage(turn),
      ..list.map(results, fn(result) {
        types.ToolResultMessage(result.call_id, result.content)
      })
    ]),
  )
}
