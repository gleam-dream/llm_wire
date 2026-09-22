import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import llm_wire/internal/api
import llm_wire/internal/google
import llm_wire/internal/provider_config
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/types
import tool_fixtures

// Behavioral ports from ReqLLM v1.24.0 (Apache-2.0), pinned at
// /private/tmp/req_llm_v1.24.0_oracle. Each case below retains the upstream
// trigger and observable assertion while adapting only the construction and
// JSON inspection to LLM Wire's typed preparation contract.

pub fn req_llm_message_test_assistant_message_with_multiple_content_parts_port() {
  let assert Ok(key) = types.api_key("oracle-key")
  let assert Ok(endpoint) = types.endpoint("https://api.example.test/v1")
  let assert Ok(model) = types.model_id("gpt-test")
  let config = provider_config.OpenAIConfig(key, endpoint, None, None)
  let request =
    types.new_request(model, [
      types.AssistantContent([
        types.TextContent("Here's the image:"),
        types.ImageUrlContent("https://example.com/pic.jpg"),
      ]),
    ])
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  let body = api.prepared_request_json(prepared)
  string.contains(
    body,
    "\"type\":\"output_text\",\"text\":\"Here's the image:\"",
  )
  |> should.be_true
  string.contains(
    body,
    "\"type\":\"input_image\",\"image_url\":\"https://example.com/pic.jpg\"",
  )
  |> should.be_true
}

pub fn req_llm_responses_api_test_encodes_structured_tool_outputs_port() {
  let assert Ok(key) = types.api_key("oracle-key")
  let assert Ok(endpoint) = types.endpoint("https://api.example.test/v1")
  let assert Ok(model) = types.model_id("gpt-test")
  let assert Ok(call_id) = types.call_id("call_1")
  let assert Ok(tool_name) = types.tool_name("get_weather")
  let request =
    types.new_request(model, [
      types.AssistantToolCalls([
        types.ToolCall(call_id, tool_name, "{\"location\":\"SF\"}", None, None),
      ]),
      types.ToolResultMessage(call_id, "{\"temp\":72}"),
    ])
  let config = provider_config.OpenAIConfig(key, endpoint, None, None)
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  let body = api.prepared_request_json(prepared)
  string.contains(body, "\"type\":\"function_call_output\"")
  |> should.be_true
  string.contains(body, "\"call_id\":\"call_1\"") |> should.be_true
  string.contains(body, "\"output\":\"{\\\"temp\\\":72}\"")
  |> should.be_true
}

pub fn req_llm_responses_api_test_encodes_input_messages_port() {
  let assert Ok(key) = types.api_key("oracle-key")
  let assert Ok(endpoint) = types.endpoint("https://api.example.test/v1")
  let assert Ok(model) = types.model_id("gpt-5")
  let request =
    types.new_request(model, [
      types.UserContent([types.TextContent("Hello")]),
      types.AssistantContent([types.TextContent("Hi there")]),
    ])
  let config = provider_config.OpenAIConfig(key, endpoint, None, None)
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  let body = api.prepared_request_json(prepared)
  string.contains(
    body,
    "\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Hello\"}]},{\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hi there\"}]}]",
  )
  |> should.be_true
}

// Local provider-specific regressions. These deliberately stay outside the
// ReqLLM port inventory because their triggers or assertions are LLM Wire
// contracts rather than behavior exercised by the selected upstream cases.

pub fn local_google_context_tool_continuation_order_test() {
  let assert Ok(key) = types.api_key("oracle-key")
  let assert Ok(endpoint) =
    types.endpoint("https://generativelanguage.example.test")
  let assert Ok(model) = types.model_id("gemini-test")
  let assert Ok(call_id) = types.call_id("call_1")
  let assert Ok(tool_name) = types.tool_name("get_weather")
  let request =
    types.new_request(model, [
      types.UserMessage("Weather in Paris?"),
      types.AssistantToolCalls([
        types.ToolCall(
          call_id,
          tool_name,
          "{\"city\":\"Paris\"}",
          Some("provider-call-1"),
          None,
        ),
      ]),
      types.ToolResultMessage(call_id, "{\"temperature\":72}"),
    ])
  let config = provider_config.GoogleConfig(key, endpoint, None)
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  let body = api.prepared_request_json(prepared)
  string.contains(body, "\"role\":\"model\",\"parts\":[{\"functionCall\"")
  |> should.be_true
  string.contains(body, "\"name\":\"get_weather\"") |> should.be_true
  string.contains(body, "\"role\":\"user\",\"parts\":[{\"functionResponse\"")
  |> should.be_true
  string.contains(body, "\"id\":\"provider-call-1\"") |> should.be_true
}

// Local provider-specific regressions. These deliberately stay outside the
// ReqLLM port inventory because their triggers or assertions are LLM Wire
// contracts rather than behavior exercised by the selected upstream cases.

pub fn local_openai_inline_multimodal_content_admission_test() {
  let assert Ok(key) = types.api_key("oracle-key")
  let assert Ok(endpoint) = types.endpoint("https://api.example.test/v1")
  let assert Ok(model) = types.model_id("gpt-test")
  let config = provider_config.OpenAIConfig(key, endpoint, None, None)
  let request =
    types.new_request(model, [
      types.UserContent([
        types.TextContent("describe"),
        types.InlineImageContent("image/png", "aW1hZ2U="),
      ]),
    ])
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  let body = api.prepared_request_json(prepared)
  body
  |> string.contains(
    "\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,aW1hZ2U=\"",
  )
  |> should.be_true
}

pub fn local_google_cache_reference_encoding_test() {
  let assert Ok(key) = types.api_key("oracle-key")
  let assert Ok(endpoint) =
    types.endpoint("https://generativelanguage.example.test")
  let assert Ok(model) = types.model_id("gemini-test")
  let config = provider_config.GoogleConfig(key, endpoint, None)
  let request =
    types.with_prompt_cache(
      types.new_request(model, [types.UserMessage("continue")]),
      types.GoogleCachedContent("cachedContents/oracle"),
    )
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  api.prepared_request_json(prepared)
  |> string.contains("\"cachedContent\":\"cachedContents/oracle\"")
  |> should.be_true
}

pub fn local_google_provider_state_reducer_test() {
  let tool = tool_fixtures.int_field_tool("lookup", "value")
  let assert Ok(reducer) = google.new_with_tools(types.default_limits(), [tool])
  let event =
    sse.ServerSentEvent(
      event: Some("message"),
      data: "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"lookup\",\"id\":\"call_1\",\"args\":{\"value\":1}},\"thoughtSignature\":\"sig_123\"}]}}]}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = google.step(reducer, event)
  case google.terminal(reducer) {
    Some(stream_types.StreamFinished(
      stream_types.CompletedToolCallsWithContinuation(_, [call], _, _),
      _,
    )) -> call.provider_state |> should.equal(Some("sig_123"))
    _ -> should.fail()
  }
}
