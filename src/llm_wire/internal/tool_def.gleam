import gleam/list
import gleam/string
import json/blueprint/codec
import json/blueprint/contract
import json/blueprint/value
import llm_wire/error
import llm_wire/internal/schema as output_schema

/// An admitted tool declaration. Built only by `llm_wire/tool`.
pub opaque type Tool {
  Tool(
    name: String,
    description: String,
    schema: codec.Schema,
    contract: contract.Contract,
    decode: fn(contract.ValidatedValue) -> Result(Nil, codec.DecodeError),
  )
}

pub fn new(
  name: String,
  description: String,
  schema: codec.Schema,
  contract: contract.Contract,
  decode: fn(contract.ValidatedValue) -> Result(Nil, codec.DecodeError),
) -> Tool {
  Tool(name:, description:, schema:, contract:, decode:)
}

pub fn name(tool: Tool) -> String {
  tool.name
}

pub fn description(tool: Tool) -> String {
  tool.description
}

pub fn schema(tool: Tool) -> codec.Schema {
  tool.schema
}

/// Why a name falls outside `^[a-zA-Z0-9_-]{1,64}$`.
pub type NameCheck {
  NameEmpty
  NameCharacter(character: String)
  NameLength(length: Int)
}

pub fn check_name(raw: String) -> Result(Nil, NameCheck) {
  case raw {
    "" -> Error(NameEmpty)
    _ ->
      case list.find(string.to_graphemes(raw), fn(c) { !is_name_char(c) }) {
        Ok(character) -> Error(NameCharacter(character))
        Error(Nil) ->
          case string.byte_size(raw) > 64 {
            True -> Error(NameLength(string.byte_size(raw)))
            False -> Ok(Nil)
          }
      }
  }
}

fn is_name_char(grapheme: String) -> Bool {
  case <<grapheme:utf8>> {
    <<c>> ->
      { c >= 0x61 && c <= 0x7A }
      || { c >= 0x41 && c <= 0x5A }
      || { c >= 0x30 && c <= 0x39 }
      || c == 0x5F
      || c == 0x2D
    _ -> False
  }
}

/// Parse, schema-validate and natively decode argument text within
/// `max_bytes`.
pub fn check_arguments(
  tool: Tool,
  max_bytes: Int,
  arguments_json: String,
) -> Result(Nil, error.ValueFailure) {
  let bounds = value.default_limits() |> value.with_max_bytes(max_bytes)
  case value.parse(arguments_json, bounds) {
    Error(problem) -> Error(error.InvalidJson(problem))
    Ok(parsed) ->
      case contract.validate(tool.contract, parsed) {
        Error(problem) -> Error(error.SchemaRejected(problem))
        Ok(validated) ->
          case tool.decode(validated) {
            Ok(Nil) -> Ok(Nil)
            Error(problem) -> Error(error.DecodeRejected(problem))
          }
      }
  }
}

/// Parse structured output within `max_bytes`, remove each `null` the
/// schema allows only as absence (`schema.drop_absent_nulls`), then validate
/// and decode it. The answer text, returned with the output or the failure,
/// is the cleaned JSON when a member was removed and `text` unchanged
/// otherwise, including when `text` is not JSON.
pub fn decode_output(
  output_contract: contract.Contract,
  schema: codec.Schema,
  output_codec: codec.Codec(a),
  text: String,
  max_bytes: Int,
) -> Result(#(a, String), #(error.ValueFailure, String)) {
  let bounds = value.default_limits() |> value.with_max_bytes(max_bytes)
  case value.parse(text, bounds) {
    Error(problem) -> Error(#(error.InvalidJson(problem), text))
    Ok(parsed) -> {
      let #(cleaned, removed) = output_schema.drop_absent_nulls(schema, parsed)
      let reported = case removed {
        True -> value.to_string(cleaned)
        False -> text
      }
      case contract.validate(output_contract, cleaned) {
        Error(problem) -> Error(#(error.SchemaRejected(problem), reported))
        Ok(validated) ->
          case contract.decode(output_codec, validated) {
            Error(problem) -> Error(#(error.DecodeRejected(problem), reported))
            Ok(decoded) -> Ok(#(decoded, reported))
          }
      }
    }
  }
}
