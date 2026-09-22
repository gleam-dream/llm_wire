import gleam/float
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import json/blueprint/codec
import json/blueprint/number
import json/blueprint/parser
import json/blueprint/runtime
import json/blueprint/value
import llm_wire/types

/// Converts Blueprint's canonical schema projection to ordinary provider JSON.
/// Blueprint owns the schema semantics; this module only bridges its value
/// representation to the provider envelope representation.
pub fn codec_schema_to_json(
  schema: codec.Schema,
) -> Result(json.Json, types.WireError) {
  blueprint_value_to_json(codec.schema_value(schema))
}

fn blueprint_value_to_json(
  source: value.Value,
) -> Result(json.Json, types.WireError) {
  case source {
    value.Null -> Ok(json.null())
    value.Bool(item) -> Ok(json.bool(item))
    value.String(item) -> Ok(json.string(item))
    value.Number(item) -> number_to_json(item)
    value.Array(items) -> {
      let empty: Result(List(json.Json), types.WireError) = Ok([])
      use encoded <- result.try(
        list.fold(items, empty, fn(acc, item) {
          use prior <- result.try(acc)
          use encoded_item <- result.try(blueprint_value_to_json(item))
          Ok(list.append(prior, [encoded_item]))
        }),
      )
      Ok(json.array(encoded, fn(item) { item }))
    }
    value.Object(fields) -> {
      let empty: Result(List(#(String, json.Json)), types.WireError) = Ok([])
      use encoded <- result.try(
        list.fold(fields, empty, fn(acc, field) {
          use prior <- result.try(acc)
          use encoded_value <- result.try(blueprint_value_to_json(field.1))
          Ok(list.append(prior, [#(field.0, encoded_value)]))
        }),
      )
      Ok(json.object(encoded))
    }
  }
}

fn number_to_json(
  number_value: number.Number,
) -> Result(json.Json, types.WireError) {
  case number.is_integer(number_value) {
    True ->
      case number.integer_projection_limit(64) {
        Ok(limit) ->
          case number.to_int_exact(number_value, limit) {
            Ok(integer) -> Ok(json.int(integer))
            Error(_) -> number_to_float_json(number_value)
          }
        Error(_) -> number_to_float_json(number_value)
      }
    False -> number_to_float_json(number_value)
  }
}

fn number_to_float_json(
  number_value: number.Number,
) -> Result(json.Json, types.WireError) {
  let text = number.number_text(number_value)
  case float.parse(text) {
    Error(Nil) ->
      Error(types.PreparationError(
        "Number schema bound cannot be represented as a JSON number",
      ))
    Ok(projected) -> {
      let encoded = json.float(projected)
      case
        parser.parse_value_from_string(
          parser.default_limits(),
          json.to_string(encoded),
        )
      {
        Ok(value.Number(round_tripped)) ->
          case number.compare(number_value, round_tripped) {
            number.EqualTo -> Ok(encoded)
            _ ->
              Error(types.PreparationError(
                "Number schema bound cannot be represented exactly as a JSON number",
              ))
          }
        _ ->
          Error(types.PreparationError(
            "Number schema bound cannot be represented exactly as a JSON number",
          ))
      }
    }
  }
}

/// Converts only the provider schema subset this adapter currently admits.
/// Unsupported Blueprint variants fail locally instead of being weakened into
/// a different JSON Schema during request preparation.
pub fn provider_schema(
  schema: codec.Schema,
) -> Result(json.Json, types.WireError) {
  case provider_schema_supported(schema) {
    True -> codec_schema_to_json(schema)
    False ->
      Error(types.PreparationError(
        "Tool schema uses a Blueprint variant not admitted by this provider profile",
      ))
  }
}

/// Projects the Blueprint subset admitted by Google's JSON Schema field.
/// Google exposes this under `parametersJsonSchema`; it is deliberately kept
/// as a provider-specific admission point even though its supported value
/// projection currently matches the common OpenAI-compatible subset.
pub fn google_function_parameters_schema(
  schema: codec.Schema,
) -> Result(json.Json, types.WireError) {
  provider_schema(schema)
}

fn provider_schema_supported(schema: codec.Schema) -> Bool {
  case schema {
    codec.StringSchema
    | codec.StringEnumSchema(_)
    | codec.IntSchema
    | codec.NumberSchema
    | codec.BoolSchema
    | codec.IntegerRangeSchema(_, _) -> True
    codec.ListSchema(item)
    | codec.NullableSchema(item)
    | codec.FieldSchema(_, item) -> provider_schema_supported(item)
    codec.ObjectSchema(properties) ->
      list.all(properties, fn(property) {
        provider_schema_supported(property.schema)
      })
    codec.PairSchema(_, _)
    | codec.TaggedSchema(_, _, _, _)
    | codec.NumberRangeSchema(_, _) -> False
  }
}

/// Strict structured-output schemas require a closed object at the root and
/// closed, fully required object properties recursively.
pub fn strict_output_schema(
  schema: codec.Schema,
) -> Result(json.Json, types.WireError) {
  case schema {
    codec.ObjectSchema(_) -> strict_schema(schema)
    _ ->
      Error(types.PreparationError(
        "Structured output requires an object root schema",
      ))
  }
}

fn strict_schema(schema: codec.Schema) -> Result(json.Json, types.WireError) {
  use Nil <- result.try(validate_strict_schema(schema))
  codec_schema_to_json(schema)
}

fn validate_strict_schema(
  schema: codec.Schema,
) -> Result(Nil, types.WireError) {
  case schema {
    codec.StringSchema
    | codec.StringEnumSchema(_)
    | codec.IntSchema
    | codec.IntegerRangeSchema(_, _)
    | codec.NumberSchema
    | codec.BoolSchema -> Ok(Nil)
    codec.ListSchema(item)
    | codec.NullableSchema(item)
    | codec.FieldSchema(_, item) -> validate_strict_schema(item)
    codec.ObjectSchema(properties) -> {
      case list.any(properties, fn(property) { !property.required }) {
        True ->
          Error(types.PreparationError(
            "Strict structured output requires every object property to be required",
          ))
        False ->
          list.fold(properties, Ok(Nil), fn(acc, property) {
            use Nil <- result.try(acc)
            validate_strict_schema(property.schema)
          })
      }
    }
    codec.PairSchema(_, _)
    | codec.TaggedSchema(_, _, _, _)
    | codec.NumberRangeSchema(_, _) ->
      Error(types.PreparationError(
        "Structured output uses an unsupported Blueprint schema variant",
      ))
  }
}

pub fn google_strict_output_schema(
  schema: codec.Schema,
) -> Result(json.Json, types.WireError) {
  case schema {
    codec.ObjectSchema(_) -> google_strict_schema(schema)
    _ ->
      Error(types.PreparationError(
        "Structured output requires an object root schema",
      ))
  }
}

fn google_strict_schema(
  schema: codec.Schema,
) -> Result(json.Json, types.WireError) {
  use Nil <- result.try(validate_google_strict_schema(schema))
  codec_schema_to_json(schema)
}

fn validate_google_strict_schema(
  schema: codec.Schema,
) -> Result(Nil, types.WireError) {
  case schema {
    codec.NullableSchema(_) ->
      Error(types.PreparationError(
        "Google structured output does not support nullable/anyOf schema",
      ))
    codec.ObjectSchema(properties) -> {
      case list.any(properties, fn(property) { !property.required }) {
        True ->
          Error(types.PreparationError(
            "Strict structured output requires every object property to be required",
          ))
        False ->
          list.fold(properties, Ok(Nil), fn(acc, property) {
            use Nil <- result.try(acc)
            validate_google_strict_schema(property.schema)
          })
      }
    }
    codec.FieldSchema(_, inner) | codec.ListSchema(inner) ->
      validate_google_strict_schema(inner)
    codec.StringSchema
    | codec.StringEnumSchema(_)
    | codec.IntSchema
    | codec.IntegerRangeSchema(_, _)
    | codec.NumberSchema
    | codec.BoolSchema -> Ok(Nil)
    codec.PairSchema(_, _)
    | codec.TaggedSchema(_, _, _, _)
    | codec.NumberRangeSchema(_, _) ->
      Error(types.PreparationError(
        "Structured output uses an unsupported Blueprint schema variant",
      ))
  }
}

/// Validates raw tool argument JSON string against an admitted Blueprint runtime contract.
pub fn validate_tool_arguments(
  contract: runtime.RuntimeContract,
  args_json: String,
) -> Result(Nil, types.WireError) {
  case parser.parse_value_from_string(parser.default_limits(), args_json) {
    Error(_) ->
      Error(types.ProtocolError("Invalid JSON in tool call arguments"))
    Ok(val) ->
      case runtime.validate(contract, val) {
        Error(err) ->
          Error(types.ProtocolError(
            "Tool call arguments failed schema validation: "
            <> string.inspect(err),
          ))
        Ok(_) -> Ok(Nil)
      }
  }
}

/// Validates structured output string against an admitted Blueprint runtime contract
/// and decodes using the target codec.
pub fn validate_and_decode_structured_output(
  contract: runtime.RuntimeContract,
  output_codec: codec.Codec(a),
  output_json: String,
) -> Result(a, types.WireError) {
  case parser.parse_value_from_string(parser.default_limits(), output_json) {
    Error(_) ->
      Error(types.OutputValidationError("Invalid JSON in structured output"))
    Ok(val) ->
      case runtime.validate(contract, val) {
        Error(err) ->
          Error(types.OutputValidationError(
            "Structured output failed schema validation: "
            <> string.inspect(err),
          ))
        Ok(validated) ->
          case runtime.decode(output_codec, validated) {
            Error(err) ->
              Error(types.OutputValidationError(
                "Structured output failed codec decode: " <> string.inspect(err),
              ))
            Ok(decoded) -> Ok(decoded)
          }
      }
  }
}
