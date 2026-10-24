import gleam/json
import gleam/list
import gleam/option.{None, Some}
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
/// closed, fully required object properties recursively. A union below the
/// root is sent as `anyOf` of strict objects, each with its tag as a
/// single-value `enum` (see `strict_unions`); a union at the root is refused,
/// because OpenAI's strict mode rejects an `anyOf` root and the other
/// providers share the object-root rule.
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
  strict_unions_json(schema)
}

fn google_strict_schema(schema: codec.Schema) -> Result(json.Json, String) {
  use Nil <- result.try(validate_google_strict_schema(schema))
  strict_unions_json(schema)
}

fn strict_unions_json(schema: codec.Schema) -> Result(json.Json, String) {
  codec.schema_value(schema)
  |> strict_unions
  |> value.to_json
  |> result.replace_error(
    "Number schema bound cannot be represented exactly as a JSON number",
  )
}

/// Rewrites each union Blueprint renders as `{"type": "object", "oneOf":
/// [..]}` into `{"anyOf": [..]}`, the form the providers' structured output
/// accepts, and each variant's tag `{"const": t}` into `{"type": "string",
/// "enum": [t]}`. Every variant stays a closed object with a required
/// `tag` and, with a payload, `value`, so the reply keeps the JSON shape the
/// original codec decodes. Nothing else is changed.
fn strict_unions(document: value.Value) -> value.Value {
  case document {
    value.Object(members) ->
      case list.key_find(members, "type"), list.key_find(members, "oneOf") {
        Ok(value.String("object")), Ok(value.Array(variants)) ->
          value.Object([
            #(
              "anyOf",
              value.Array(
                list.map(variants, fn(variant) {
                  variant |> strict_unions |> strict_tag
                }),
              ),
            ),
          ])
        _, _ ->
          value.Object(
            list.map(members, fn(member) {
              #(member.0, strict_unions(member.1))
            }),
          )
      }
    value.Array(items) -> value.Array(list.map(items, strict_unions))
    other -> other
  }
}

fn strict_tag(variant: value.Value) -> value.Value {
  case variant {
    value.Object(members) ->
      value.Object(
        list.map(members, fn(member) {
          case member {
            #("properties", value.Object(properties)) -> #(
              "properties",
              value.Object(
                list.map(properties, fn(property) {
                  case property {
                    #("tag", value.Object([#("const", tag)])) -> #(
                      "tag",
                      value.Object([
                        #("type", value.String("string")),
                        #("enum", value.Array([tag])),
                      ]),
                    )
                    other -> other
                  }
                }),
              ),
            )
            other -> other
          }
        }),
      )
    other -> other
  }
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
    codec.UnionSchema(variants) ->
      validate_variants(variants, validate_strict_schema)
    // Strict mode needs a `type`: `{}` and an unknown kind cannot give one.
    codec.PairSchema(_, _)
    | codec.NumberRangeSchema(_, _)
    | codec.AnySchema
    | codec.OtherSchema(_) ->
      Error("Structured output uses an unsupported Blueprint schema variant")
  }
}

/// Each variant is a closed object with a required tag, so only its payload
/// needs checking.
fn validate_variants(
  variants: List(codec.VariantSchema),
  validate: fn(codec.Schema) -> Result(Nil, String),
) -> Result(Nil, String) {
  list.try_each(variants, fn(variant) {
    case variant.payload {
      Some(payload) -> validate(payload)
      None -> Ok(Nil)
    }
  })
}

pub fn google_strict_output_schema(
  schema: codec.Schema,
) -> Result(json.Json, String) {
  case object_root(schema) {
    True -> google_strict_schema(schema)
    False -> Error("Structured output requires an object root schema")
  }
}

/// Gemini's `responseJsonSchema` takes JSON Schema with `required`,
/// `anyOf` with `{"type": "null"}`, `minimum`/`maximum` and `prefixItems`
/// (Google's structured-output guide, checked live on `gemini-3.8-flash`).
/// So, unlike the strict profile, it admits `codec.nullable`, optional
/// fields, number ranges and pairs.
fn validate_google_strict_schema(schema: codec.Schema) -> Result(Nil, String) {
  case codec.view(schema) {
    codec.ObjectSchema(properties) ->
      list.try_each(properties, fn(property) {
        validate_google_strict_schema(property.schema)
      })
    codec.ListSchema(inner) | codec.NullableSchema(inner) ->
      validate_google_strict_schema(inner)
    codec.PairSchema(left, right) -> {
      use Nil <- result.try(validate_google_strict_schema(left))
      validate_google_strict_schema(right)
    }
    codec.StringSchema
    | codec.StringEnumSchema(_)
    | codec.IntSchema
    | codec.IntegerRangeSchema(_, _)
    | codec.NumberSchema
    | codec.NumberRangeSchema(_, _)
    | codec.AnySchema
    | codec.BoolSchema -> Ok(Nil)
    codec.UnionSchema(variants) ->
      validate_variants(variants, validate_google_strict_schema)
    codec.OtherSchema(_) ->
      Error("Structured output uses an unsupported Blueprint schema variant")
  }
}
