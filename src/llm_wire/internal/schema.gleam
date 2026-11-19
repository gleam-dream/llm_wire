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
/// closed, fully required object properties recursively. An optional
/// property is sent required and nullable (see `require_all`); the answer's
/// `null` for it is removed again by `drop_absent_nulls`. A union below the
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
  codec.schema_value(schema) |> require_all |> strict_unions |> provider_json
}

fn google_strict_schema(schema: codec.Schema) -> Result(json.Json, String) {
  use Nil <- result.try(validate_google_strict_schema(schema))
  codec.schema_value(schema) |> strict_unions |> provider_json
}

fn provider_json(document: value.Value) -> Result(json.Json, String) {
  document
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

/// Lists every property of each closed object Blueprint renders in its
/// `required`, and makes each property that was not required nullable, in
/// Blueprint's own nullable form `{"anyOf": [{"type": "null"}, schema]}`. A
/// property already nullable keeps its schema. Applied before
/// `strict_unions`, it reaches union payloads too, since Blueprint renders a
/// variant as a closed object.
fn require_all(document: value.Value) -> value.Value {
  case document {
    value.Object(members) ->
      case
        list.key_find(members, "type"),
        list.key_find(members, "properties"),
        list.key_find(members, "required")
      {
        Ok(value.String("object")),
          Ok(value.Object(properties)),
          Ok(value.Array(required))
        -> {
          let properties =
            list.map(properties, fn(property) {
              let #(name, schema) = property
              let schema = require_all(schema)
              case list.contains(required, value.String(name)) {
                True -> #(name, schema)
                False -> #(name, nullable(schema))
              }
            })
          let names =
            list.map(properties, fn(property) { value.String(property.0) })
          value.Object(
            list.map(members, fn(member) {
              case member.0 {
                "properties" -> #("properties", value.Object(properties))
                "required" -> #("required", value.Array(names))
                _ -> #(member.0, require_all(member.1))
              }
            }),
          )
        }
        _, _, _ ->
          value.Object(
            list.map(members, fn(member) { #(member.0, require_all(member.1)) }),
          )
      }
    value.Array(items) -> value.Array(list.map(items, require_all))
    other -> other
  }
}

fn nullable(schema: value.Value) -> value.Value {
  let null = value.Object([#("type", value.String("null"))])
  let admits_null = case schema {
    value.Object(members) ->
      case list.key_find(members, "anyOf") {
        Ok(value.Array(choices)) -> list.contains(choices, null)
        _ -> False
      }
    _ -> False
  }
  case admits_null {
    True -> schema
    False -> value.Object([#("anyOf", value.Array([null, schema]))])
  }
}

/// Removes, recursively, each `null` member of `document` where `schema`
/// declares the property optional and the property's own schema admits no
/// `null` (it is neither nullable nor `codec.value()`). Such a `null` can
/// only mean absence, and the original codec refuses it. Returns the value
/// and whether anything was removed; anything the schema does not describe
/// is left for validation.
pub fn drop_absent_nulls(
  schema: codec.Schema,
  document: value.Value,
) -> #(value.Value, Bool) {
  case codec.view(schema), document {
    // Members are written in the schema's property order, the order a
    // strict schema asks the model for; the native parser keeps none.
    // Members the schema does not name follow, for validation to refuse.
    codec.ObjectSchema(properties), value.Object(members) -> {
      let #(kept, removed) =
        list.fold(properties, #([], False), fn(acc, property) {
          let #(kept, removed) = acc
          case list.key_find(members, property.name) {
            Error(Nil) -> acc
            Ok(item) ->
              case item, property.required, admits_null(property.schema) {
                value.Null, False, False -> #(kept, True)
                _, _, _ -> {
                  let #(item, changed) =
                    drop_absent_nulls(property.schema, item)
                  #([#(property.name, item), ..kept], removed || changed)
                }
              }
          }
        })
      let unknown =
        list.filter(members, fn(member) {
          !list.any(properties, fn(property) { property.name == member.0 })
        })
      #(value.Object(list.append(list.reverse(kept), unknown)), removed)
    }
    codec.NullableSchema(inner), item -> drop_absent_nulls(inner, item)
    codec.ListSchema(items), value.Array(elements) -> {
      let #(elements, removed) =
        list.fold(elements, #([], False), fn(acc, element) {
          let #(element, changed) = drop_absent_nulls(items, element)
          #([element, ..acc.0], acc.1 || changed)
        })
      #(value.Array(list.reverse(elements)), removed)
    }
    codec.PairSchema(left, right), value.Array([first, second]) -> {
      let #(first, left_changed) = drop_absent_nulls(left, first)
      let #(second, right_changed) = drop_absent_nulls(right, second)
      #(value.Array([first, second]), left_changed || right_changed)
    }
    codec.UnionSchema(variants), value.Object(members) ->
      case list.key_find(members, "tag"), list.key_find(members, "value") {
        Ok(value.String(tag)), Ok(payload) ->
          case list.find(variants, fn(variant) { variant.tag == tag }) {
            Ok(codec.VariantSchema(payload: Some(payload_schema), ..)) -> {
              let #(payload, changed) =
                drop_absent_nulls(payload_schema, payload)
              #(
                value.Object(
                  list.map(members, fn(member) {
                    case member.0 {
                      "value" -> #("value", payload)
                      _ -> member
                    }
                  }),
                ),
                changed,
              )
            }
            _ -> #(document, False)
          }
        _, _ -> #(document, False)
      }
    _, _ -> #(document, False)
  }
}

fn admits_null(schema: codec.Schema) -> Bool {
  case codec.view(schema) {
    codec.NullableSchema(_) | codec.AnySchema | codec.OtherSchema(_) -> True
    _ -> False
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
    codec.ObjectSchema(properties) ->
      list.try_each(properties, fn(property) {
        validate_strict_schema(property.schema)
      })
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
