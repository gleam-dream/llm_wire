import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import json/blueprint/number
import json/blueprint/parser
import json/blueprint/value
import llm_wire/internal/api
import llm_wire/internal/provider_config
import llm_wire/internal/schema
import llm_wire/telemetry
import llm_wire/types
import sinal
import tool_fixtures

pub fn prepare_openai_request_uses_responses_wire_test() {
  let assert Ok(key) = types.api_key("test-key")
  let assert Ok(endpoint) = types.endpoint("http://127.0.0.1:4321/v1/")
  let assert Ok(model) = types.model_id("gpt-test")
  let config =
    provider_config.OpenAIConfig(key, endpoint, None, Some("project-test"))
  let request =
    types.new_request(model, [types.UserMessage("hello")])
    |> types.with_tools([tool_fixtures.int_field_tool("sum", "value")])
    |> types.with_max_tokens(256)

  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  api.prepared_provider(prepared) |> should.equal(types.OpenAI)
  api.prepared_path(prepared) |> should.equal("/v1/responses")
  let body = api.prepared_request_json(prepared)
  body |> string.contains("\"model\":\"gpt-test\"") |> should.be_true
  body |> string.contains("\"input\"") |> should.be_true
  body |> string.contains("\"max_output_tokens\":256") |> should.be_true
  body |> string.contains("\"type\":\"function\"") |> should.be_true
  let assert Ok(actual) =
    parser.parse_value_from_string(parser.default_limits(), body)
  let assert Some(value.Array([value.Object(tool_fields), ..])) =
    object_field(actual, "tools")
  let assert Some(actual_schema) = find_field(tool_fields, "parameters")
  let assert Ok(contract_schema) =
    codec.schema(codec.field("value", codec.int()))
  actual_schema |> should.equal(codec.schema_value(contract_schema))
}

pub fn codec_schema_json_encodes_exact_blueprint_field_schema_and_numeric_bounds_test() {
  let assert Ok(field_schema) = codec.schema(codec.field("value", codec.int()))
  let assert Ok(field_json) = schema.codec_schema_to_json(field_schema)
  field_json
  |> should.equal(
    json.object([
      #("type", json.string("object")),
      #(
        "properties",
        json.object([
          #("value", json.object([#("type", json.string("integer"))])),
        ]),
      ),
      #("required", json.array([json.string("value")], fn(item) { item })),
      #("additionalProperties", json.bool(False)),
    ]),
  )

  let assert Ok(number_limits) = number.number_limits(64, 64, 64)
  let assert Ok(minimum) = number.parse_number(number_limits, "1.5")
  let assert Ok(maximum) = number.parse_number(number_limits, "2.5")
  let assert Ok(range_codec) = codec.number_between(minimum, maximum)
  let assert Ok(range_schema) = codec.schema(range_codec)
  let assert Ok(range_json) = schema.codec_schema_to_json(range_schema)
  range_json
  |> should.equal(
    json.object([
      #("type", json.string("number")),
      #("minimum", json.float(1.5)),
      #("maximum", json.float(2.5)),
    ]),
  )
}

pub fn codec_schema_projection_matches_blueprint_for_recursive_forms_test() {
  let schemas = [
    codec.StringSchema,
    codec.StringEnumSchema(["red", "blue"]),
    codec.IntSchema,
    codec.NumberSchema,
    codec.BoolSchema,
    codec.ListSchema(codec.NullableSchema(codec.StringSchema)),
    codec.NullableSchema(codec.FieldSchema("label", codec.StringSchema)),
    codec.FieldSchema("enabled", codec.BoolSchema),
    codec.ObjectSchema([
      codec.PropertySchema("name", True, codec.StringSchema),
      codec.PropertySchema(
        "nickname",
        False,
        codec.NullableSchema(codec.StringSchema),
      ),
    ]),
    codec.IntegerRangeSchema(-5, 12),
  ]

  list.each(schemas, fn(contract_schema) {
    let assert Ok(projected_json) = schema.codec_schema_to_json(contract_schema)
    let assert Ok(projected_value) =
      parser.parse_value_from_string(
        parser.default_limits(),
        json.to_string(projected_json),
      )
    projected_value |> should.equal(codec.schema_value(contract_schema))
  })
}

fn object_field(object: value.Value, name: String) -> Option(value.Value) {
  case object {
    value.Object(fields) -> find_field(fields, name)
    _ -> None
  }
}

fn find_field(
  fields: List(#(String, value.Value)),
  name: String,
) -> Option(value.Value) {
  case fields {
    [] -> None
    [#(key, item), ..] if key == name -> Some(item)
    [_, ..rest] -> find_field(rest, name)
  }
}

pub fn prepare_anthropic_request_uses_messages_wire_test() {
  let assert Ok(key) = types.api_key("test-key")
  let assert Ok(endpoint) = types.endpoint("https://api.example.test/v1")
  let assert Ok(model) = types.model_id("claude-test")
  let config =
    provider_config.AnthropicConfig(key, endpoint, Some("2025-01-01"))
  let request =
    types.new_request(model, [
      types.SystemMessage("be concise"),
      types.UserMessage("hello"),
    ])
    |> types.with_tools([tool_fixtures.int_field_tool("sum", "value")])
    |> types.with_stop_sequences(["END"])

  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  api.prepared_path(prepared) |> should.equal("/v1/messages")
  let body = api.prepared_request_json(prepared)
  body |> string.contains("\"system\":\"be concise\"") |> should.be_true
  body |> string.contains("\"max_tokens\":1024") |> should.be_true
  body |> string.contains("\"input_schema\"") |> should.be_true
  body |> string.contains("\"stop_sequences\":[\"END\"]") |> should.be_true
}

pub fn prepare_openai_request_encodes_typed_multimodal_content_test() {
  let assert Ok(key) = types.api_key("test-key")
  let assert Ok(endpoint) = types.endpoint("https://api.example.test/v1")
  let assert Ok(model) = types.model_id("gpt-test")
  let config = provider_config.OpenAIConfig(key, endpoint, None, None)
  let request =
    types.new_request(model, [
      types.UserContent([
        types.TextContent("describe this"),
        types.ImageUrlContent("https://example.test/image.png"),
        types.InlineImageContent("image/png", "aGVsbG8="),
      ]),
    ])
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  let body = api.prepared_request_json(prepared)
  body
  |> string.contains("\"type\":\"input_text\",\"text\":\"describe this\"")
  |> should.be_true
  body
  |> string.contains(
    "\"type\":\"input_image\",\"image_url\":\"https://example.test/image.png\"",
  )
  |> should.be_true
  body
  |> string.contains(
    "\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,aGVsbG8=\"",
  )
  |> should.be_true
}

pub fn prepare_anthropic_request_encodes_inline_image_content_test() {
  let assert Ok(key) = types.api_key("test-key")
  let assert Ok(endpoint) = types.endpoint("https://api.example.test/v1")
  let assert Ok(model) = types.model_id("claude-test")
  let config = provider_config.AnthropicConfig(key, endpoint, None)
  let request =
    types.new_request(model, [
      types.UserContent([
        types.TextContent("what is shown"),
        types.InlineImageContent("image/jpeg", "aW1hZ2U="),
      ]),
    ])
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  let body = api.prepared_request_json(prepared)
  body
  |> string.contains("\"type\":\"text\",\"text\":\"what is shown\"")
  |> should.be_true
  body
  |> string.contains(
    "\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/jpeg\",\"data\":\"aW1hZ2U=\"}",
  )
  |> should.be_true
}

pub fn prepare_google_request_encodes_inline_image_and_rejects_url_test() {
  let assert Ok(key) = types.api_key("test-key")
  let assert Ok(endpoint) =
    types.endpoint("https://generativelanguage.example.test")
  let assert Ok(model) = types.model_id("gemini-test")
  let config = provider_config.GoogleConfig(key, endpoint, None)
  let request =
    types.new_request(model, [
      types.UserContent([
        types.TextContent("read this"),
        types.InlineImageContent("image/webp", "d2VicA=="),
      ]),
    ])
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  let body = api.prepared_request_json(prepared)
  body |> string.contains("\"text\":\"read this\"") |> should.be_true
  body
  |> string.contains(
    "\"inlineData\":{\"mimeType\":\"image/webp\",\"data\":\"d2VicA==\"}",
  )
  |> should.be_true

  let url_request =
    types.new_request(model, [
      types.UserContent([
        types.ImageUrlContent("https://example.test/image.png"),
      ]),
    ])
  case api.prepare(config, url_request, types.default_limits()) {
    Error(types.PreparationError(reason)) ->
      reason
      |> string.contains("does not support image URLs")
      |> should.be_true
    _ -> should.fail()
  }
}

pub fn provider_prompt_cache_references_are_encoded_and_scoped_test() {
  let assert Ok(key) = types.api_key("test-key")
  let assert Ok(model) = types.model_id("gpt-test")
  let assert Ok(openai_endpoint) = types.endpoint("https://api.example.test/v1")
  let openai_config =
    provider_config.OpenAIConfig(key, openai_endpoint, None, None)
  let openai_request =
    types.with_prompt_cache(
      types.new_request(model, [types.UserMessage("hello")]),
      types.OpenAiPromptCacheKey("stable-prompt-v1"),
    )
  let assert Ok(prepared) =
    api.prepare(openai_config, openai_request, types.default_limits())
  api.prepared_request_json(prepared)
  |> string.contains("\"prompt_cache_key\":\"stable-prompt-v1\"")
  |> should.be_true

  let assert Ok(google_endpoint) =
    types.endpoint("https://generativelanguage.example.test")
  let google_config = provider_config.GoogleConfig(key, google_endpoint, None)
  let google_request =
    types.with_prompt_cache(
      types.new_request(model, [types.UserMessage("hello")]),
      types.GoogleCachedContent("cachedContents/example"),
    )
  let assert Ok(google_prepared) =
    api.prepare(google_config, google_request, types.default_limits())
  api.prepared_request_json(google_prepared)
  |> string.contains("\"cachedContent\":\"cachedContents/example\"")
  |> should.be_true

  let invalid_google =
    types.with_prompt_cache(
      types.new_request(model, [types.UserMessage("hello")]),
      types.OpenAiPromptCacheKey("wrong-provider"),
    )
  case api.prepare(google_config, invalid_google, types.default_limits()) {
    Error(types.PreparationError(reason)) ->
      reason
      |> string.contains("cannot be used with the Google profile")
      |> should.be_true
    _ -> should.fail()
  }
}

pub fn preparation_rejects_non_loopback_plain_http_test() {
  let assert Ok(key) = types.api_key("test-key")
  let assert Ok(endpoint) = types.endpoint("http://api.example.test/v1")
  let assert Ok(model) = types.model_id("gpt-test")
  let config = provider_config.OpenAIConfig(key, endpoint, None, None)
  let request = types.new_request(model, [types.UserMessage("hello")])
  case api.prepare(config, request, types.default_limits()) {
    Error(types.ConfigurationError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn preparation_rejects_unsupported_openai_stop_sequences_test() {
  let assert Ok(key) = types.api_key("test-key")
  let assert Ok(endpoint) = types.endpoint("https://api.example.test/v1")
  let assert Ok(model) = types.model_id("gpt-test")
  let config = provider_config.OpenAIConfig(key, endpoint, None, None)
  let request =
    types.new_request(model, [types.UserMessage("hello")])
    |> types.with_stop_sequences(["stop"])
  case api.prepare(config, request, types.default_limits()) {
    Error(types.PreparationError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn structured_output_is_admitted_and_decoded_with_native_codec_test() {
  let assert Ok(key) = types.api_key("test-key")
  let assert Ok(endpoint) = types.endpoint("https://api.example.test/v1")
  let assert Ok(model) = types.model_id("gpt-test")
  let config = provider_config.OpenAIConfig(key, endpoint, None, None)
  let request = types.new_request(model, [types.UserMessage("return a count")])
  let output_codec = codec.object(codec.required("answer", codec.int()))
  let assert Ok(prepared) =
    api.prepare_structured(
      config,
      request,
      types.default_limits(),
      "answer_shape",
      output_codec,
    )
  let body = api.structured_request_json(prepared)
  body |> string.contains("\"type\":\"json_schema\"") |> should.be_true
  body |> string.contains("\"strict\":true") |> should.be_true
  body |> string.contains("\"additionalProperties\":false") |> should.be_true

  api.decode_structured_output(prepared, "{\"answer\":42}")
  |> should.equal(Ok(42))
  case api.decode_structured_output(prepared, "{\"answer\":\"wrong\"}") {
    Error(types.OutputValidationError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn structured_output_rejects_optional_strict_schema_test() {
  let assert Ok(key) = types.api_key("test-key")
  let assert Ok(endpoint) = types.endpoint("https://api.example.test/v1")
  let assert Ok(model) = types.model_id("gpt-test")
  let config = provider_config.OpenAIConfig(key, endpoint, None, None)
  let request = types.new_request(model, [types.UserMessage("hello")])
  let output_codec = codec.object(codec.optional("note", codec.string()))
  case
    api.prepare_structured(
      config,
      request,
      types.default_limits(),
      "optional_shape",
      output_codec,
    )
  {
    Error(types.PreparationError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn lifecycle_observation_contains_only_fixed_metadata_test() {
  let event = telemetry.observation_event()
  let assert Ok(handler_id) = sinal.handler_id("llm_wire_api_observation_test")
  let received = process.new_subject()
  let assert Ok(attachment) =
    sinal.observe(handler_id, event, fn(_measurements, metadata) {
      process.send(received, metadata)
    })

  telemetry.observe(telemetry.Prepared, "openai", "accepted")
  let assert Ok(metadata) = process.receive(received, 1000)
  metadata
  |> should.equal(telemetry.Metadata("prepared", "openai", "accepted"))
  let _ = sinal.detach(attachment)
}
