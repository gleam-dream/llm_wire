import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import json/blueprint/codec
import json/blueprint/contract
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/google
import llm_wire/internal/schema
import llm_wire/openai
import llm_wire/tool
import tool_fixtures

fn single_field_schema() -> codec.Schema {
  codec.ObjectSchema([codec.PropertySchema("answer", True, codec.IntSchema)])
}

fn builtin_configs() -> List(llm_wire.Config) {
  [
    openai.new("test-key") |> openai.config,
    anthropic.new("test-key") |> anthropic.config,
    google.new("test-key") |> google.config,
  ]
}

pub fn described_tool_schema_survives_contract_and_provider_projection_test() {
  let input =
    tool_fixtures.one_field(
      "city",
      codec.describe(codec.string(), "City to look up"),
    )
    |> codec.describe("Weather request")
  let assert Ok(input_contract) = contract.from_codec(input)
  let assert Ok(weather) =
    tool.from_contract("lookup_weather", "Look up weather", input_contract)
  let assert Ok(projected) = schema.provider_schema(tool.schema(weather))
  projected
  |> should.equal(
    json.object([
      #("description", json.string("Weather request")),
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #(
            "city",
            json.object([
              #("description", json.string("City to look up")),
              #("type", json.string("string")),
            ]),
          ),
        ]),
      ),
      #("required", json.array([json.string("city")], fn(item) { item })),
      #("additionalProperties", json.bool(False)),
    ]),
  )
  schema.strict_output_schema(tool.schema(weather)) |> should.be_ok
  schema.google_strict_output_schema(tool.schema(weather)) |> should.be_ok

  let request =
    llm_wire.request("model-test", [llm_wire.user("weather")])
    |> llm_wire.with_tools([weather])
  builtin_configs()
  |> list.all(fn(config) {
    let assert Ok(prepared) = llm_wire.prepare(config, request)
    let wire = llm_wire.request_json(prepared)
    string.contains(wire, "\"description\":\"Weather request\"")
    && string.contains(wire, "\"description\":\"City to look up\"")
  })
  |> should.be_true
}

pub fn strict_admission_projects_single_field_object_schema_test() {
  let assert Ok(field_json) = schema.strict_output_schema(single_field_schema())
  let assert Ok(google_field_json) =
    schema.google_strict_output_schema(single_field_schema())
  google_field_json |> should.equal(field_json)
  field_json
  |> should.equal(
    json.object([
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #("answer", json.object([#("type", json.string("integer"))])),
        ]),
      ),
      #("required", json.array([json.string("answer")], fn(item) { item })),
      #("additionalProperties", json.bool(False)),
    ]),
  )
}

pub fn configured_structured_prepare_accepts_field_codec_for_all_providers_test() {
  let request =
    llm_wire.request("model-test", [llm_wire.user("answer")])
    |> llm_wire.with_output(
      "answer_shape",
      tool_fixtures.one_field("answer", codec.int()),
    )
  list.each(builtin_configs(), fn(config) {
    let assert Ok(prepared) = llm_wire.prepare(config, request)
    llm_wire.request_json(prepared)
    |> string.contains("\"additionalProperties\":false")
    |> should.be_true
  })
}

pub fn optional_field_is_not_converted_to_nullable_required_test() {
  let optional =
    codec.ObjectSchema([codec.PropertySchema("answer", False, codec.IntSchema)])
  // Projections now return a plain reason; `prepare` wraps it in
  // `error.UnsupportedSchema(error.Output, reason)`.
  let reason =
    "Strict structured output requires every object property to be required"
  schema.strict_output_schema(optional) |> should.equal(Error(reason))
  schema.google_strict_output_schema(optional) |> should.be_error
  let output = {
    use item <- codec.optional_field("answer", codec.int(), get: fn(item) {
      item
    })
    codec.success(item)
  }
  let request =
    llm_wire.request("model-test", [llm_wire.user("answer")])
    |> llm_wire.with_output("optional_shape", output)
  list.each(builtin_configs(), fn(config) {
    llm_wire.prepare(config, request)
    |> should.equal(Error(error.UnsupportedSchema(error.Output, reason)))
  })
}

pub fn unsupported_vocabulary_and_google_nullable_restriction_remain_test() {
  let unsupported =
    codec.ObjectSchema([
      codec.PropertySchema(
        "answer",
        True,
        codec.PairSchema(codec.IntSchema, codec.IntSchema),
      ),
    ])
  schema.strict_output_schema(unsupported) |> should.be_error
  schema.google_strict_output_schema(unsupported) |> should.be_error

  let nullable =
    codec.ObjectSchema([
      codec.PropertySchema(
        "answer",
        True,
        codec.NullableSchema(codec.IntSchema),
      ),
    ])
  schema.strict_output_schema(nullable) |> should.be_ok
  schema.google_strict_output_schema(nullable)
  |> should.equal(Error(
    "Google structured output does not support nullable/anyOf schema",
  ))
}
