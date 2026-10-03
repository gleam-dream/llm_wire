import json/blueprint/codec
import llm_wire/tool

/// An object with one required property, decoded to the property's value.
pub fn one_field(name: String, inner: codec.Codec(a)) -> codec.Codec(a) {
  use item <- codec.field(name, inner, get: fn(item) { item })
  codec.success(item)
}

pub fn string_field_tool(name: String, field: String) -> tool.Tool {
  tool.new(name, "Fixture tool", one_field(field, codec.string()))
}

pub fn int_field_tool(name: String, field: String) -> tool.Tool {
  tool.new(name, "Fixture tool", one_field(field, codec.int()))
}
