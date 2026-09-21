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

/// Converts an admitted Blueprint schema into its exact JSON Schema form.
/// Schemas outside this module's supported JSON representation fail explicitly.
pub fn codec_schema_to_json(
  schema: codec.Schema,
) -> Result(json.Json, types.WireError) {
  case schema {
    codec.StringSchema -> Ok(json.object([#("type", json.string("string"))]))

    codec.IntSchema -> Ok(json.object([#("type", json.string("integer"))]))

    codec.NumberSchema -> Ok(json.object([#("type", json.string("number"))]))

    codec.BoolSchema -> Ok(json.object([#("type", json.string("boolean"))]))

    codec.StringEnumSchema(labels) ->
      Ok(
        json.object([
          #("type", json.string("string")),
          #("enum", json.array(labels, json.string)),
        ]),
      )

    codec.ListSchema(item_schema) -> {
      use item_json <- result.try(codec_schema_to_json(item_schema))
      Ok(
        json.object([
          #("type", json.string("array")),
          #("items", item_json),
        ]),
      )
    }

    codec.NullableSchema(inner) -> {
      use inner_json <- result.try(codec_schema_to_json(inner))
      Ok(
        json.object([
          #(
            "anyOf",
            json.array(
              [
                json.object([#("type", json.string("null"))]),
                inner_json,
              ],
              fn(x) { x },
            ),
          ),
        ]),
      )
    }

    codec.ObjectSchema(props) -> {
      let empty: Result(List(#(String, json.Json)), types.WireError) = Ok([])
      use prop_fields <- result.try(
        list.fold(props, empty, fn(acc, prop) {
          use prior <- result.try(acc)
          use prop_json <- result.try(codec_schema_to_json(prop.schema))
          Ok(list.append(prior, [#(prop.name, prop_json)]))
        }),
      )
      let required_names =
        list.filter_map(props, fn(prop) {
          case prop.required {
            True -> Ok(prop.name)
            False -> Error(Nil)
          }
        })
      Ok(
        json.object([
          #("type", json.string("object")),
          #("properties", json.object(prop_fields)),
          #("required", json.array(required_names, json.string)),
          #("additionalProperties", json.bool(False)),
        ]),
      )
    }

    codec.FieldSchema(name, inner) -> {
      use inner_json <- result.try(codec_schema_to_json(inner))
      Ok(
        json.object([
          #("type", json.string("object")),
          #("properties", json.object([#(name, inner_json)])),
          #("required", json.array([name], json.string)),
          #("additionalProperties", json.bool(False)),
        ]),
      )
    }

    codec.IntegerRangeSchema(min, max) ->
      Ok(
        json.object([
          #("type", json.string("integer")),
          #("minimum", json.int(min)),
          #("maximum", json.int(max)),
        ]),
      )

    codec.NumberRangeSchema(min, max) -> {
      use minimum <- result.try(number_to_json(min))
      use maximum <- result.try(number_to_json(max))
      Ok(
        json.object([
          #("type", json.string("number")),
          #("minimum", minimum),
          #("maximum", maximum),
        ]),
      )
    }

    codec.PairSchema(_, _) | codec.TaggedSchema(_, _, _, _) ->
      Error(types.PreparationError(
        "Schema form has no exact supported JSON Schema representation",
      ))
  }
}

fn number_to_json(
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
  case schema {
    codec.StringSchema -> Ok(json.object([#("type", json.string("string"))]))
    codec.StringEnumSchema(values) ->
      Ok(
        json.object([
          #("type", json.string("string")),
          #("enum", json.array(values, json.string)),
        ]),
      )
    codec.IntSchema -> Ok(json.object([#("type", json.string("integer"))]))
    codec.IntegerRangeSchema(minimum, maximum) ->
      Ok(
        json.object([
          #("type", json.string("integer")),
          #("minimum", json.int(minimum)),
          #("maximum", json.int(maximum)),
        ]),
      )
    codec.NumberSchema -> Ok(json.object([#("type", json.string("number"))]))
    codec.BoolSchema -> Ok(json.object([#("type", json.string("boolean"))]))
    codec.ListSchema(item) -> {
      use item_schema <- result.try(strict_schema(item))
      Ok(
        json.object([
          #("type", json.string("array")),
          #("items", item_schema),
        ]),
      )
    }
    codec.NullableSchema(inner) -> {
      use inner_schema <- result.try(strict_schema(inner))
      Ok(
        json.object([
          #(
            "anyOf",
            json.array(
              [
                inner_schema,
                json.object([#("type", json.string("null"))]),
              ],
              fn(value) { value },
            ),
          ),
        ]),
      )
    }
    codec.FieldSchema(_, inner) -> strict_schema(inner)
    codec.ObjectSchema(properties) -> {
      case list.any(properties, fn(property) { !property.required }) {
        True ->
          Error(types.PreparationError(
            "Strict structured output requires every object property to be required",
          ))
        False -> {
          let empty: Result(List(#(String, json.Json)), types.WireError) =
            Ok([])
          use encoded <- result.try(
            list.fold(properties, empty, fn(acc, property) {
              use prior <- result.try(acc)
              use property_schema <- result.try(strict_schema(property.schema))
              Ok(list.append(prior, [#(property.name, property_schema)]))
            }),
          )
          let required = list.map(properties, fn(property) { property.name })
          Ok(
            json.object([
              #("type", json.string("object")),
              #("properties", json.object(encoded)),
              #("required", json.array(required, json.string)),
              #("additionalProperties", json.bool(False)),
            ]),
          )
        }
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
