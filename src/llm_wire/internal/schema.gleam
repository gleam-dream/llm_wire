import gleam/json
import gleam/list
import gleam/result
import json/blueprint/codec
import json/blueprint/contract
import json/blueprint/value
import llm_wire/types

/// Converts Blueprint's canonical schema projection to ordinary provider JSON.
/// Blueprint owns the schema semantics and the exact number conversion.
pub fn codec_schema_to_json(
  schema: codec.Schema,
) -> Result(json.Json, types.WireError) {
  codec.schema_value(schema)
  |> value.to_json
  |> result.replace_error(types.PreparationError(
    "Number schema bound cannot be represented exactly as a JSON number",
  ))
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
    codec.DescribedSchema(_, inner) -> provider_schema_supported(inner)
    codec.StringSchema
    | codec.StringEnumSchema(_)
    | codec.IntSchema
    | codec.NumberSchema
    | codec.BoolSchema
    | codec.IntegerRangeSchema(_, _) -> True
    codec.ListSchema(item) | codec.NullableSchema(item) ->
      provider_schema_supported(item)
    codec.ObjectSchema(properties) ->
      list.all(properties, fn(property) {
        provider_schema_supported(property.schema)
      })
    codec.PairSchema(_, _)
    | codec.UnionSchema(_)
    | codec.NumberRangeSchema(_, _) -> False
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

/// Strict structured-output schemas require a closed object at the root and
/// closed, fully required object properties recursively.
pub fn strict_output_schema(
  schema: codec.Schema,
) -> Result(json.Json, types.WireError) {
  case object_root(schema) {
    True -> strict_schema(schema)
    False ->
      Error(types.PreparationError(
        "Structured output requires an object root schema",
      ))
  }
}

fn object_root(schema: codec.Schema) -> Bool {
  case schema {
    codec.DescribedSchema(_, inner) -> object_root(inner)
    codec.ObjectSchema(_) -> True
    _ -> False
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
    codec.DescribedSchema(_, inner) -> validate_strict_schema(inner)
    codec.StringSchema
    | codec.StringEnumSchema(_)
    | codec.IntSchema
    | codec.IntegerRangeSchema(_, _)
    | codec.NumberSchema
    | codec.BoolSchema -> Ok(Nil)
    codec.ListSchema(item) | codec.NullableSchema(item) ->
      validate_strict_schema(item)
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
    | codec.UnionSchema(_)
    | codec.NumberRangeSchema(_, _) ->
      Error(types.PreparationError(
        "Structured output uses an unsupported Blueprint schema variant",
      ))
  }
}

pub fn google_strict_output_schema(
  schema: codec.Schema,
) -> Result(json.Json, types.WireError) {
  case object_root(schema) {
    True -> google_strict_schema(schema)
    False ->
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
    codec.DescribedSchema(_, inner) -> validate_google_strict_schema(inner)
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
    codec.ListSchema(inner) -> validate_google_strict_schema(inner)
    codec.StringSchema
    | codec.StringEnumSchema(_)
    | codec.IntSchema
    | codec.IntegerRangeSchema(_, _)
    | codec.NumberSchema
    | codec.BoolSchema -> Ok(Nil)
    codec.PairSchema(_, _)
    | codec.UnionSchema(_)
    | codec.NumberRangeSchema(_, _) ->
      Error(types.PreparationError(
        "Structured output uses an unsupported Blueprint schema variant",
      ))
  }
}

/// Validates structured output string against an admitted Blueprint contract
/// and decodes using the target codec.
pub fn validate_and_decode_structured_output(
  output_contract: contract.Contract,
  output_codec: codec.Codec(a),
  output_json: String,
  max_bytes: Int,
) -> Result(a, types.WireError) {
  let parser_bounds = value.default_limits() |> value.with_max_bytes(max_bytes)
  case value.parse(output_json, parser_bounds) {
    Error(_) ->
      Error(types.OutputValidationError("Invalid JSON in structured output"))
    Ok(val) ->
      case contract.validate(output_contract, val) {
        Error(err) ->
          Error(types.OutputValidationError(
            "Structured output failed schema validation: "
            <> contract.describe_validation_error(err),
          ))
        Ok(validated) ->
          case contract.decode(output_codec, validated) {
            Error(err) ->
              Error(types.OutputValidationError(
                "Structured output failed codec decode: "
                <> codec.describe_decode_error(err),
              ))
            Ok(decoded) -> Ok(decoded)
          }
      }
  }
}
