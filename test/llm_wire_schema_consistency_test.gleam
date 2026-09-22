import gleam/json
import gleam/string
import gleeunit/should
import json/blueprint/codec
import llm_wire/config
import llm_wire/internal/schema
import llm_wire/session
import llm_wire/types

fn single_field_schema() -> codec.Schema {
  codec.FieldSchema("answer", codec.IntSchema)
}

fn equivalent_object_schema() -> codec.Schema {
  codec.ObjectSchema([codec.PropertySchema("answer", True, codec.IntSchema)])
}

pub fn strict_admission_normalizes_field_and_object_schema_test() {
  let assert Ok(field_json) = schema.strict_output_schema(single_field_schema())
  let assert Ok(object_json) =
    schema.strict_output_schema(equivalent_object_schema())
  field_json |> should.equal(object_json)
  let assert Ok(google_field_json) =
    schema.google_strict_output_schema(single_field_schema())
  let assert Ok(google_object_json) =
    schema.google_strict_output_schema(equivalent_object_schema())
  google_field_json |> should.equal(google_object_json)
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
  let assert Ok(key) = types.api_key("test-key")
  let assert Ok(model) = types.model_id("model-test")
  let request = types.new_request(model, [types.UserMessage("answer")])
  let output_codec = codec.field("answer", codec.int())

  let assert Ok(openai) =
    session.prepare_structured(
      config.openai(key),
      request,
      "answer_shape",
      output_codec,
    )
  let assert Ok(anthropic) =
    session.prepare_structured(
      config.anthropic(key),
      request,
      "answer_shape",
      output_codec,
    )
  let assert Ok(google) =
    session.prepare_structured(
      config.google(key),
      request,
      "answer_shape",
      output_codec,
    )
  session.structured_request_json(openai)
  |> string.contains("\"additionalProperties\":false")
  |> should.be_true
  session.structured_request_json(anthropic)
  |> string.contains("\"additionalProperties\":false")
  |> should.be_true
  session.structured_request_json(google)
  |> string.contains("\"additionalProperties\":false")
  |> should.be_true
}

pub fn optional_field_is_not_converted_to_nullable_required_test() {
  let optional =
    codec.ObjectSchema([codec.PropertySchema("answer", False, codec.IntSchema)])
  case schema.strict_output_schema(optional) {
    Error(types.PreparationError(message)) ->
      message
      |> should.equal(
        "Strict structured output requires every object property to be required",
      )
    _ -> should.fail()
  }
  schema.google_strict_output_schema(optional) |> should.be_error
}

pub fn unsupported_vocabulary_and_google_nullable_restriction_remain_test() {
  let unsupported =
    codec.FieldSchema(
      "answer",
      codec.PairSchema(codec.IntSchema, codec.IntSchema),
    )
  schema.strict_output_schema(unsupported) |> should.be_error
  schema.google_strict_output_schema(unsupported) |> should.be_error

  let nullable =
    codec.FieldSchema("answer", codec.NullableSchema(codec.IntSchema))
  schema.strict_output_schema(nullable) |> should.be_ok
  case schema.google_strict_output_schema(nullable) {
    Error(types.PreparationError(message)) ->
      message
      |> should.equal(
        "Google structured output does not support nullable/anyOf schema",
      )
    _ -> should.fail()
  }
}
