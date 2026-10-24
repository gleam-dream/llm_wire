import gleam/erlang/process
import gleam/http
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import http_gun/destination
import http_gun/error as http_error
import http_gun/testing as http_testing
import http_test_helpers
import json/blueprint/codec
import json/blueprint/contract
import json/blueprint/number
import json/blueprint/value
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/google
import llm_wire/internal/api
import llm_wire/internal/call
import llm_wire/internal/schema
import llm_wire/internal/tool_def
import llm_wire/limit
import llm_wire/message
import llm_wire/openai
import llm_wire/provider
import llm_wire/telemetry
import llm_wire/testing
import llm_wire/tool
import sinal
import tool_fixtures

/// The HTTP request a prepared call sends, as HTTP Gun records it.
fn sent_request(prepared: llm_wire.Prepared(o)) {
  http_testing.request(testing.exchange(prepared, testing.text("")))
}

fn provider_of(prepared: llm_wire.Prepared(o)) -> message.Provider {
  api.provider(call.prepared_call(prepared))
}

pub fn prepare_openai_request_uses_responses_wire_test() {
  let config =
    openai.new("test-key")
    |> openai.with_project("project-test")
    |> openai.config
    |> llm_wire.with_endpoint("http://127.0.0.1:4321/v1/")
  let request =
    llm_wire.request("gpt-test", [llm_wire.user("hello")])
    |> llm_wire.with_tools([tool_fixtures.int_field_tool("sum", "value")])
    |> llm_wire.with_max_tokens(256)

  let assert Ok(prepared) = llm_wire.prepare(config, request)
  provider_of(prepared) |> should.equal(message.OpenAI)
  sent_request(prepared).path |> should.equal("/v1/responses")
  let body = llm_wire.request_json(prepared)
  body |> string.contains("\"model\":\"gpt-test\"") |> should.be_true
  body |> string.contains("\"input\"") |> should.be_true
  body |> string.contains("\"max_output_tokens\":256") |> should.be_true
  body |> string.contains("\"type\":\"function\"") |> should.be_true
  let assert Ok(actual) = value.parse(body, value.default_limits())
  let assert Some(value.Array([value.Object(tool_fields), ..])) =
    object_field(actual, "tools")
  let assert Some(actual_schema) = find_field(tool_fields, "parameters")
  let assert Ok(contract_schema) =
    codec.schema(tool_fixtures.one_field("value", codec.int()))
  actual_schema |> should.equal(codec.schema_value(contract_schema))
}

pub fn schema_only_tool_validates_json_without_a_native_codec_test() {
  let assert Ok(input_contract) =
    contract.from_codec(tool_fixtures.one_field("id", codec.int()))
  let assert Ok(lookup) =
    tool.from_contract("remote_lookup", "Lookup", input_contract)
  // `types.validate_tool_arguments` became the runtime's internal
  // admission check, which now returns a typed `ValueFailure`.
  tool_def.check_arguments(lookup, 128, "{\"id\":7}") |> should.be_ok
  let assert Error(error.SchemaRejected(_)) =
    tool_def.check_arguments(lookup, 128, "{\"id\":\"seven\"}")
  let assert Error(error.InvalidJson(_)) =
    tool_def.check_arguments(lookup, 5, "{\"id\":7}")

  let config =
    openai.new("test-key")
    |> openai.config
    |> llm_wire.with_endpoint("http://127.0.0.1:4321/v1")
  let request =
    llm_wire.request("gpt-test", [llm_wire.user("lookup")])
    |> llm_wire.with_tools([lookup])
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  llm_wire.request_json(prepared)
  |> string.contains("\"name\":\"remote_lookup\"")
  |> should.be_true
}

pub fn schema_only_tool_rejects_unsupported_projection_test() {
  let assert Ok(input_contract) =
    contract.from_codec(codec.pair(codec.int(), codec.int()))
  let assert Ok(unsupported) =
    tool.from_contract("unsupported", "Unsupported", input_contract)
  let request =
    llm_wire.request("gpt-test", [llm_wire.user("test")])
    |> llm_wire.with_tools([unsupported])
  let assert Error(error.UnsupportedSchema(error.ToolInput("unsupported"), _)) =
    llm_wire.prepare(
      openai.new("test-key")
        |> openai.config
        |> llm_wire.with_endpoint("http://127.0.0.1:4321/v1"),
      request,
    )
  // A custom adapter projects with Blueprint's canonical schema by default.
  let assert Ok(_) = llm_wire.prepare(testing.config(), request)
}

/// A custom adapter whose reducer ends with the event's data as the final
/// text, without streaming it as progress, so the text reaches the
/// structured-output parser without passing the per-block progress bound.
fn final_text_config() -> llm_wire.Config {
  provider.new(
    message.Custom("final-text"),
    "https://final.example.test/v1",
    fn(request, _tools, _format) {
      Ok(provider.encoded(
        "/final",
        json.to_string(json.object([#("model", json.string(request.model))])),
      ))
    },
    fn() {
      provider.reducer(
        None,
        fn(_state: Option(String), event: provider.Event) {
          Ok(#(Some(event.data), []))
        },
        fn(state) { option.map(state, provider.text(_, None)) },
      )
    },
  )
  |> provider.config
}

pub fn structured_parser_uses_admitted_text_bound_test() {
  let raw = "{\"answer\":7}"
  let raw_bytes = string.byte_size(raw)
  let reply = testing.events(["event: final\ndata: " <> raw <> "\n\n"])
  let request =
    llm_wire.request("gpt-test", [llm_wire.user("answer")])
    |> llm_wire.with_output(
      "answer_shape",
      tool_fixtures.one_field("answer", codec.int()),
    )
  let limited =
    final_text_config()
    |> llm_wire.with_limit(limit.TextBytesPerBlock, raw_bytes - 1)
  let assert Ok(prepared) = llm_wire.prepare(limited, request)
  // `decode_structured_output` is gone; the bound now shows as an invalid
  // output failure of the executed call.
  let assert Error(failure) = http_test_helpers.run_reply(prepared, reply)
  let assert error.InvalidOutput(raw_output, error.InvalidJson(_)) =
    failure.error
  raw_output |> should.equal(raw)
  let allowed =
    final_text_config()
    |> llm_wire.with_limit(limit.TextBytesPerBlock, raw_bytes)
  let assert Ok(prepared_allowed) = llm_wire.prepare(allowed, request)
  let assert Ok(llm_wire.Answer(output: 7, ..)) =
    http_test_helpers.run_reply(prepared_allowed, reply)
}

pub fn codec_schema_json_encodes_exact_blueprint_field_schema_and_numeric_bounds_test() {
  let assert Ok(field_schema) =
    codec.schema(tool_fixtures.one_field("value", codec.int()))
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

  let number_limits = number.limits(64, 64, 64)
  let assert Ok(minimum) = number.parse("1.5", number_limits)
  let assert Ok(maximum) = number.parse("2.5", number_limits)
  let range_codec = codec.number_between(minimum, maximum)
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
    schema_of(codec.string()),
    schema_of(codec.string_enum([#("red", "red"), #("blue", "blue")])),
    schema_of(codec.int()),
    schema_of(codec.number()),
    schema_of(codec.bool()),
    schema_of(codec.list(codec.nullable(codec.string()))),
    schema_of(codec.nullable(tool_fixtures.one_field("label", codec.string()))),
    schema_of(tool_fixtures.one_field("enabled", codec.bool())),
    schema_of({
      use name <- codec.field(
        "name",
        codec.string(),
        get: fn(item: #(String, Option(String))) { item.0 },
      )
      use nickname <- codec.optional_field(
        "nickname",
        codec.nullable(codec.string()),
        get: fn(item: #(String, Option(String))) { Some(item.1) },
      )
      codec.success(#(name, option.flatten(nickname)))
    }),
    schema_of(codec.integer_between(-5, 12)),
    schema_of(codec.value()),
  ]

  list.each(schemas, fn(contract_schema) {
    let assert Ok(projected_json) = schema.codec_schema_to_json(contract_schema)
    let assert Ok(projected_value) =
      value.parse(json.to_string(projected_json), value.default_limits())
    projected_value |> should.equal(codec.schema_value(contract_schema))
  })
}

fn schema_of(input: codec.Codec(a)) -> codec.Schema {
  let assert Ok(schema) = codec.schema(input)
  schema
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
  let config =
    anthropic.new("test-key")
    |> anthropic.with_version("2025-01-01")
    |> anthropic.config
    |> llm_wire.with_endpoint("https://api.example.test/v1")
  let request =
    llm_wire.request("claude-test", [
      llm_wire.system("be concise"),
      llm_wire.user("hello"),
    ])
    |> llm_wire.with_tools([tool_fixtures.int_field_tool("sum", "value")])
    |> llm_wire.with_stop_sequences(["END"])

  let assert Ok(prepared) = llm_wire.prepare(config, request)
  let sent = sent_request(prepared)
  sent.path |> should.equal("/v1/messages")
  sent.headers
  |> list.contains(#("anthropic-version", "2025-01-01"))
  |> should.be_true
  let body = llm_wire.request_json(prepared)
  body |> string.contains("\"system\":\"be concise\"") |> should.be_true
  body |> string.contains("\"max_tokens\":1024") |> should.be_true
  body |> string.contains("\"input_schema\"") |> should.be_true
  body |> string.contains("\"stop_sequences\":[\"END\"]") |> should.be_true
}

pub fn prepare_openai_request_encodes_typed_multimodal_content_test() {
  let config =
    openai.new("test-key")
    |> openai.config
    |> llm_wire.with_endpoint("https://api.example.test/v1")
  let request =
    llm_wire.request("gpt-test", [
      message.UserParts([
        message.TextPart("describe this"),
        message.ImageUrlPart("https://example.test/image.png"),
        message.InlineImagePart("image/png", "aGVsbG8="),
      ]),
    ])
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  let body = llm_wire.request_json(prepared)
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
  let config =
    anthropic.new("test-key")
    |> anthropic.config
    |> llm_wire.with_endpoint("https://api.example.test/v1")
  let request =
    llm_wire.request("claude-test", [
      message.UserParts([
        message.TextPart("what is shown"),
        message.InlineImagePart("image/jpeg", "aW1hZ2U="),
      ]),
    ])
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  let body = llm_wire.request_json(prepared)
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
  let config =
    google.new("test-key")
    |> google.config
    |> llm_wire.with_endpoint("https://generativelanguage.example.test")
  let request =
    llm_wire.request("gemini-test", [
      message.UserParts([
        message.TextPart("read this"),
        message.InlineImagePart("image/webp", "d2VicA=="),
      ]),
    ])
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  let body = llm_wire.request_json(prepared)
  body |> string.contains("\"text\":\"read this\"") |> should.be_true
  body
  |> string.contains(
    "\"inlineData\":{\"mimeType\":\"image/webp\",\"data\":\"d2VicA==\"}",
  )
  |> should.be_true

  let url_request =
    llm_wire.request("gemini-test", [
      message.UserParts([
        message.ImageUrlPart("https://example.test/image.png"),
      ]),
    ])
  llm_wire.prepare(config, url_request)
  |> should.equal(Error(error.InvalidRequest(error.ImageUrlUnsupported)))
}

pub fn provider_prompt_cache_references_are_encoded_and_scoped_test() {
  let openai_config =
    openai.new("test-key")
    |> openai.config
    |> llm_wire.with_endpoint("https://api.example.test/v1")
  let openai_request =
    llm_wire.request("gpt-test", [llm_wire.user("hello")])
    |> llm_wire.with_openai_prompt_cache_key("stable-prompt-v1")
  let assert Ok(prepared) = llm_wire.prepare(openai_config, openai_request)
  llm_wire.request_json(prepared)
  |> string.contains("\"prompt_cache_key\":\"stable-prompt-v1\"")
  |> should.be_true

  let google_config =
    google.new("test-key")
    |> google.config
    |> llm_wire.with_endpoint("https://generativelanguage.example.test")
  let google_request =
    llm_wire.request("gpt-test", [llm_wire.user("hello")])
    |> llm_wire.with_google_cached_content("cachedContents/example")
  let assert Ok(google_prepared) =
    llm_wire.prepare(google_config, google_request)
  llm_wire.request_json(google_prepared)
  |> string.contains("\"cachedContent\":\"cachedContents/example\"")
  |> should.be_true

  let invalid_google =
    llm_wire.request("gpt-test", [llm_wire.user("hello")])
    |> llm_wire.with_openai_prompt_cache_key("wrong-provider")
  llm_wire.prepare(google_config, invalid_google)
  |> should.equal(Error(error.InvalidRequest(error.PromptCacheUnsupported)))
}

pub fn plain_http_to_a_non_loopback_host_is_refused_by_http_gun_test() {
  // The plaintext host check moved to HTTP Gun: `prepare` admits `http://`
  // for any host, and execution refuses plaintext to a non-loopback
  // address before anything is sent.
  let hello = llm_wire.request("gpt-test", [llm_wire.user("hello")])
  let config =
    openai.new("test-key")
    |> openai.config
    |> llm_wire.with_endpoint("http://api.example.test/v1")
  let assert Ok(prepared) = llm_wire.prepare(config, hello)
  sent_request(prepared).scheme |> should.equal(http.Http)
  sent_request(prepared).host |> should.equal("api.example.test")

  let public =
    openai.new("test-key")
    |> openai.config
    |> llm_wire.with_endpoint("http://8.8.8.8:9/v1")
  let assert Ok(prepared) = llm_wire.prepare(public, hello)
  use client <- http_test_helpers.with_client
  let assert Error(failure) = llm_wire.run(client, prepared)
  let assert error.Http(http_failure) = failure.error
  http_error.reason(http_failure)
  |> should.equal(
    http_error.DestinationRejected(destination.PlaintextRefused(
      destination.Public,
    )),
  )
  failure.sent |> should.equal(llm_wire.NotSent)
}

pub fn bracketed_ipv6_loopback_endpoints_parse_test() {
  // `http://[::1]:port` endpoints are admitted now.
  let config =
    openai.new("test-key")
    |> openai.config
    |> llm_wire.with_endpoint("http://[::1]:8080/v1")
  let assert Ok(prepared) =
    llm_wire.prepare(
      config,
      llm_wire.request("gpt-test", [llm_wire.user("hello")]),
    )
  let sent = sent_request(prepared)
  sent.host |> should.equal("::1")
  sent.port |> should.equal(Some(8080))
  sent.path |> should.equal("/v1/responses")
}

pub fn preparation_rejects_unsupported_openai_stop_sequences_test() {
  let config =
    openai.new("test-key")
    |> openai.config
    |> llm_wire.with_endpoint("https://api.example.test/v1")
  let request =
    llm_wire.request("gpt-test", [llm_wire.user("hello")])
    |> llm_wire.with_stop_sequences(["stop"])
  llm_wire.prepare(config, request)
  |> should.equal(Error(error.InvalidRequest(error.StopSequencesUnsupported)))
}

pub fn structured_output_is_admitted_and_decoded_with_native_codec_test() {
  let config =
    openai.new("test-key")
    |> openai.config
    |> llm_wire.with_endpoint("https://api.example.test/v1")
  let request =
    llm_wire.request("gpt-test", [llm_wire.user("return a count")])
    |> llm_wire.with_output(
      "answer_shape",
      tool_fixtures.one_field("answer", codec.int()),
    )
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  let body = llm_wire.request_json(prepared)
  body |> string.contains("\"type\":\"json_schema\"") |> should.be_true
  body |> string.contains("\"strict\":true") |> should.be_true
  body |> string.contains("\"additionalProperties\":false") |> should.be_true

  let assert Ok(llm_wire.Answer(output: 42, ..)) =
    http_test_helpers.run_reply(
      prepared,
      testing.events_for(message.OpenAI, testing.text("{\"answer\":42}")),
    )
  // Invalid output is now a failure of the call, keeping the raw text.
  let assert Error(failure) =
    http_test_helpers.run_reply(
      prepared,
      testing.events_for(message.OpenAI, testing.text("{\"answer\":\"wrong\"}")),
    )
  let assert error.InvalidOutput(_, error.SchemaRejected(_)) = failure.error
  failure.sent |> should.equal(llm_wire.Completed)
}

pub fn structured_output_rejects_optional_strict_schema_test() {
  let config =
    openai.new("test-key")
    |> openai.config
    |> llm_wire.with_endpoint("https://api.example.test/v1")
  let output_codec = {
    use item <- codec.optional_field("note", codec.string(), get: fn(item) {
      item
    })
    codec.success(item)
  }
  let request =
    llm_wire.request("gpt-test", [llm_wire.user("hello")])
    |> llm_wire.with_output("optional_shape", output_codec)
  let assert Error(error.UnsupportedSchema(error.Output, _)) =
    llm_wire.prepare(config, request)
}

pub fn lifecycle_observation_contains_only_fixed_metadata_test() {
  let received = process.new_subject()
  let attachment =
    sinal.observe(telemetry.event(), fn(_measurements, metadata) {
      process.send(received, metadata)
    })
  // `prepare` is pure now and emits nothing; the first event marks the
  // start of execution. `telemetry.observe` is no longer public.
  let assert Ok(prepared) =
    llm_wire.prepare(
      testing.config(),
      llm_wire.request("m", [llm_wire.user("secret prompt")]),
    )
  process.receive(received, 50) |> should.equal(Error(Nil))
  let assert Ok(_) =
    http_test_helpers.run_reply(prepared, testing.text("secret answer"))
  let assert Ok(metadata) = process.receive(received, 1000)
  let _ = sinal.detach(attachment)
  let telemetry.Metadata(call:, correlation:, stage:, provider:, outcome:) =
    metadata
  stage |> should.equal(telemetry.Started)
  provider |> should.equal("scripted")
  outcome |> should.equal(telemetry.Accepted)
  correlation |> should.equal(None)
  { call != "" } |> should.be_true
  string.contains(string.inspect(metadata), "secret") |> should.be_false
}
