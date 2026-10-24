import gleam/list
import gleam/string
import json/blueprint/codec
import json/blueprint/contract
import json/blueprint/value
import llm_wire/error

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

/// Parse, validate and decode JSON text with a codec and its contract.
pub fn decode_value(
  output_contract: contract.Contract,
  output_codec: codec.Codec(a),
  text: String,
  max_bytes: Int,
) -> Result(a, error.ValueFailure) {
  let bounds = value.default_limits() |> value.with_max_bytes(max_bytes)
  case value.parse(text, bounds) {
    Error(problem) -> Error(error.InvalidJson(problem))
    Ok(parsed) ->
      case contract.validate(output_contract, parsed) {
        Error(problem) -> Error(error.SchemaRejected(problem))
        Ok(validated) ->
          case contract.decode(output_codec, validated) {
            Ok(decoded) -> Ok(decoded)
            Error(problem) -> Error(error.DecodeRejected(problem))
          }
      }
  }
}
