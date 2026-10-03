import gleam/json
import gleam/list
import gleam/result
import json/blueprint/codec
import json/blueprint/value

/// Converts Blueprint's canonical schema projection to ordinary provider JSON.
/// Blueprint owns the schema semantics and the exact number conversion.
pub fn codec_schema_to_json(schema: codec.Schema) -> Result(json.Json, String) {
  codec.schema_value(schema)
  |> value.to_json
  |> result.replace_error(
    "Number schema bound cannot be represented exactly as a JSON number",
  )
}

/// Converts only the provider schema subset this adapter currently admits.
/// Unsupported Blueprint variants fail locally instead of being weakened into
/// a different JSON Schema during request preparation. The any schema (`{}`)
/// is admitted because every provider accepts it in tool parameters. A schema
/// kind this package does not know is refused rather than forwarded unchecked.
pub fn provider_schema(schema: codec.Schema) -> Result(json.Json, String) {
  case provider_schema_support(schema) {
    Supported -> codec_schema_to_json(schema)
    Unsupported ->
      Error(
        "Tool schema uses a Blueprint variant not admitted by this provider profile",
      )
    UnknownKind ->
      Error(
        "Tool schema uses a Blueprint schema kind unknown to this provider profile",
      )
  }
}

type Support {
  Supported
  Unsupported
  UnknownKind
}

fn provider_schema_support(schema: codec.Schema) -> Support {
  case codec.view(schema) {
    codec.StringSchema
    | codec.StringEnumSchema(_)
    | codec.IntSchema
    | codec.NumberSchema
    | codec.BoolSchema
    | codec.IntegerRangeSchema(_, _)
    | codec.AnySchema -> Supported
    codec.ListSchema(item) | codec.NullableSchema(item) ->
      provider_schema_support(item)
    codec.ObjectSchema(properties) ->
      list.fold(properties, Supported, fn(acc, property) {
        combine(acc, provider_schema_support(property.schema))
      })
    codec.PairSchema(_, _)
    | codec.UnionSchema(_)
    | codec.NumberRangeSchema(_, _) -> Unsupported
    codec.OtherSchema(_) -> UnknownKind
  }
}

/// The first non-supported verdict wins, so a nested refusal keeps its reason.
fn combine(left: Support, right: Support) -> Support {
  case left {
    Supported -> right
    Unsupported | UnknownKind -> left
  }
}

/// Projects the Blueprint subset admitted by Google's JSON Schema field.
/// Google exposes this under `parametersJsonSchema`; it is deliberately kept
/// as a provider-specific admission point even though its supported value
/// projection currently matches the common OpenAI-compatible subset.
pub fn google_function_parameters_schema(
  schema: codec.Schema,
) -> Result(json.Json, String) {
  provider_schema(schema)
}

/// Strict structured-output schemas require a closed object at the root and
/// closed, fully required object properties recursively.
pub fn strict_output_schema(schema: codec.Schema) -> Result(json.Json, String) {
  case object_root(schema) {
    True -> strict_schema(schema)
    False -> Error("Structured output requires an object root schema")
  }
}

fn object_root(schema: codec.Schema) -> Bool {
  case codec.view(schema) {
    codec.ObjectSchema(_) -> True
    codec.StringSchema
    | codec.StringEnumSchema(_)
    | codec.IntSchema
    | codec.IntegerRangeSchema(_, _)
    | codec.NumberSchema
    | codec.NumberRangeSchema(_, _)
    | codec.BoolSchema
    | codec.PairSchema(_, _)
    | codec.ListSchema(_)
    | codec.NullableSchema(_)
    | codec.UnionSchema(_)
    | codec.AnySchema
    | codec.OtherSchema(_) -> False
  }
}

fn strict_schema(schema: codec.Schema) -> Result(json.Json, String) {
  use Nil <- result.try(validate_strict_schema(schema))
  codec_schema_to_json(schema)
}

fn validate_strict_schema(schema: codec.Schema) -> Result(Nil, String) {
  case codec.view(schema) {
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
          Error(
            "Strict structured output requires every object property to be required",
          )
        False ->
          list.fold(properties, Ok(Nil), fn(acc, property) {
            use Nil <- result.try(acc)
            validate_strict_schema(property.schema)
          })
      }
    }
    // Strict mode needs a `type`: `{}` and an unknown kind cannot give one.
    codec.PairSchema(_, _)
    | codec.UnionSchema(_)
    | codec.NumberRangeSchema(_, _)
    | codec.AnySchema
    | codec.OtherSchema(_) ->
      Error("Structured output uses an unsupported Blueprint schema variant")
  }
}

pub fn google_strict_output_schema(
  schema: codec.Schema,
) -> Result(json.Json, String) {
  case object_root(schema) {
    True -> google_strict_schema(schema)
    False -> Error("Structured output requires an object root schema")
  }
}

fn google_strict_schema(schema: codec.Schema) -> Result(json.Json, String) {
  use Nil <- result.try(validate_google_strict_schema(schema))
  codec_schema_to_json(schema)
}

fn validate_google_strict_schema(schema: codec.Schema) -> Result(Nil, String) {
  case codec.view(schema) {
    codec.NullableSchema(_) ->
      Error("Google structured output does not support nullable/anyOf schema")
    codec.ObjectSchema(properties) -> {
      case list.any(properties, fn(property) { !property.required }) {
        True ->
          Error(
            "Strict structured output requires every object property to be required",
          )
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
    // Strict mode needs a `type`: `{}` and an unknown kind cannot give one.
    codec.PairSchema(_, _)
    | codec.UnionSchema(_)
    | codec.NumberRangeSchema(_, _)
    | codec.AnySchema
    | codec.OtherSchema(_) ->
      Error("Structured output uses an unsupported Blueprint schema variant")
  }
}
