import json/blueprint/codec
import llm_wire/types

pub fn string_field_tool(name: String, field: String) -> types.ToolDefinition {
  let assert Ok(tool_name) = types.tool_name(name)
  let assert Ok(tool) =
    types.tool_from_codec(
      tool_name,
      "Fixture tool",
      codec.field(field, codec.string()),
    )
  tool
}

pub fn int_field_tool(name: String, field: String) -> types.ToolDefinition {
  let assert Ok(tool_name) = types.tool_name(name)
  let assert Ok(tool) =
    types.tool_from_codec(
      tool_name,
      "Fixture tool",
      codec.field(field, codec.int()),
    )
  tool
}
