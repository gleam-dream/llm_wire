import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import llm_wire
import llm_wire/google as google_options
import llm_wire/internal/google
import llm_wire/internal/limits
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/message
import llm_wire/openai

// Behavioral ports from ReqLLM v1.24.0 (Apache-2.0), pinned at
// /private/tmp/req_llm_v1.24.0_oracle. Each case below retains the upstream
// trigger and observable assertion while adapting only the construction and
// JSON inspection to LLM Wire's typed preparation contract.
//
// The three ReqLLM ports were named `..._port` and so never ran under
// gleeunit; they now end in `_port_test`.

fn openai_config() -> llm_wire.Config {
  openai.new("oracle-key")
  |> openai.config
  |> llm_wire.with_endpoint("https://api.example.test/v1")
}

fn google_config() -> llm_wire.Config {
  google_options.new("oracle-key")
  |> google_options.config
  |> llm_wire.with_endpoint("https://generativelanguage.example.test")
}

fn tool_call_turn(calls: List(message.ToolCall)) -> message.Message {
  message.Assistant(message.AssistantTurn(
    provider: None,
    text: "",
    calls:,
    response_id: None,
    provider_data: None,
  ))
}

pub fn req_llm_message_test_assistant_message_with_multiple_content_parts_port_test() {
  let request =
    llm_wire.request("gpt-test", [
      message.AssistantParts([
        message.TextPart("Here's the image:"),
        message.ImageUrlPart("https://example.com/pic.jpg"),
      ]),
    ])
  let assert Ok(prepared) = llm_wire.prepare(openai_config(), request)
  let body = llm_wire.request_json(prepared)
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

pub fn req_llm_responses_api_test_encodes_structured_tool_outputs_port_test() {
  let request =
    llm_wire.request("gpt-test", [
      tool_call_turn([
        message.tool_call("call_1", "get_weather", "{\"location\":\"SF\"}"),
      ]),
      message.ToolResult("call_1", "{\"temp\":72}"),
    ])
  let assert Ok(prepared) = llm_wire.prepare(openai_config(), request)
  let body = llm_wire.request_json(prepared)
  string.contains(body, "\"type\":\"function_call_output\"")
  |> should.be_true
  string.contains(body, "\"call_id\":\"call_1\"") |> should.be_true
  string.contains(body, "\"output\":\"{\\\"temp\\\":72}\"")
  |> should.be_true
}

pub fn req_llm_responses_api_test_encodes_input_messages_port_test() {
  let request =
    llm_wire.request("gpt-5", [
      message.UserParts([message.TextPart("Hello")]),
      message.AssistantParts([message.TextPart("Hi there")]),
    ])
  let assert Ok(prepared) = llm_wire.prepare(openai_config(), request)
  let body = llm_wire.request_json(prepared)
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
  let request =
    llm_wire.request("gemini-test", [
      message.User("Weather in Paris?"),
      tool_call_turn([
        message.ToolCall(
          id: "call_1",
          name: "get_weather",
          arguments_json: "{\"city\":\"Paris\"}",
          provider_id: Some("provider-call-1"),
          provider_state: None,
        ),
      ]),
      message.ToolResult("call_1", "{\"temperature\":72}"),
    ])
  let assert Ok(prepared) = llm_wire.prepare(google_config(), request)
  let body = llm_wire.request_json(prepared)
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
  let request =
    llm_wire.request("gpt-test", [
      message.UserParts([
        message.TextPart("describe"),
        message.InlineImagePart("image/png", "aW1hZ2U="),
      ]),
    ])
  let assert Ok(prepared) = llm_wire.prepare(openai_config(), request)
  let body = llm_wire.request_json(prepared)
  body
  |> string.contains(
    "\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,aW1hZ2U=\"",
  )
  |> should.be_true
}

pub fn local_google_cache_reference_encoding_test() {
  let request =
    llm_wire.with_google_cached_content(
      llm_wire.request("gemini-test", [message.User("continue")]),
      "cachedContents/oracle",
    )
  let assert Ok(prepared) = llm_wire.prepare(google_config(), request)
  llm_wire.request_json(prepared)
  |> string.contains("\"cachedContent\":\"cachedContents/oracle\"")
  |> should.be_true
}

pub fn local_google_provider_state_reducer_test() {
  // `new_with_tools` is gone: the runtime admits calls at the terminal.
  let reducer = google.new(limits.default())
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
      stream_types.CompletedToolCallsWithData(_, [call], _, _, []),
      _,
    )) -> call.provider_state |> should.equal(Some("sig_123"))
    _ -> should.fail()
  }
}
