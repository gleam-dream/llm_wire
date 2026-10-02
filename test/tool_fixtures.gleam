import json/blueprint/codec
import llm_wire/types

/// An object with one required property, decoded to the property's value.
pub fn one_field(name: String, inner: codec.Codec(a)) -> codec.Codec(a) {
  use item <- codec.field(name, inner, get: fn(item) { item })
  codec.success(item)
}

pub fn string_field_tool(name: String, field: String) -> types.ToolDefinition {
  let assert Ok(tool_name) = types.tool_name(name)
  let assert Ok(tool) =
    types.tool_from_codec(
      tool_name,
      "Fixture tool",
      one_field(field, codec.string()),
    )
  tool
}

pub fn int_field_tool(name: String, field: String) -> types.ToolDefinition {
  let assert Ok(tool_name) = types.tool_name(name)
  let assert Ok(tool) =
    types.tool_from_codec(
      tool_name,
      "Fixture tool",
      one_field(field, codec.int()),
    )
  tool
}
