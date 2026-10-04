import conversation_fixture
import fake_server
import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import http_test_helpers
import json/blueprint/codec
import json/blueprint/number
import llm_wire
import llm_wire/error
import llm_wire/google as google_options
import llm_wire/internal/api
import llm_wire/internal/call
import llm_wire/internal/google
import llm_wire/internal/limits
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/message
import llm_wire/tool
import tool_fixtures

fn event(data: String) -> sse.ServerSentEvent {
  sse.ServerSentEvent(event: None, data: data, id: None, retry: None)
}

fn google_config(key: String, endpoint: String) -> llm_wire.Config {
  google_options.new(key)
  |> google_options.config
  |> llm_wire.with_endpoint(endpoint)
}

fn loopback_config(port: Int) -> llm_wire.Config {
  google_config("sk-local-google", "http://127.0.0.1:" <> int.to_string(port))
}

fn path(prepared: llm_wire.Prepared(o)) -> String {
  api.path(call.prepared_call(prepared))
}

pub fn google_text_streaming_and_stop_completion_test() {
  let reducer = google.new(limits.default())

  // Chunk 1: text delta + responseId
  let chunk1 =
    "{\"responseId\":\"resp_123\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hello \"}]}}]}"
  let assert Ok(#(reducer, progress1)) = google.step(reducer, event(chunk1))
  progress1
  |> should.equal([message.TextDelta(block_id: "0", text: "Hello ")])

  // Chunk 2: text delta + usageMetadata
  let chunk2 =
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"world!\"}]}}],\"usageMetadata\":{\"promptTokenCount\":5,\"candidatesTokenCount\":3,\"totalTokenCount\":8}}"
  let assert Ok(#(reducer, progress2)) = google.step(reducer, event(chunk2))
  progress2
  |> should.equal([
    message.UsageUpdate(message.Usage(5, 3, 8)),
    message.TextDelta(block_id: "0", text: "world!"),
  ])

  // Chunk 3: finishReason STOP
  let chunk3 =
    "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}"
  let assert Ok(#(reducer, progress3)) = google.step(reducer, event(chunk3))
  progress3
  |> should.equal([])

  // Verify terminal outcome
  google.terminal(reducer)
  |> should.equal(
    Some(stream_types.StreamFinished(
      outcome: stream_types.CompletedText("Hello world!"),
      usage: Some(message.Usage(5, 3, 8)),
    )),
  )
}

pub fn google_tool_call_buffering_and_completion_test() {
  // `new_with_tools` is gone: the runtime admits calls at the terminal.
  let reducer = google.new(limits.default())

  // Tool call chunk with ID
  let chunk1 =
    "{\"responseId\":\"resp_tools\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":42},\"id\":\"call_calc_1\"}}]}}]}"
  let assert Ok(#(reducer, progress1)) = google.step(reducer, event(chunk1))
  // Crucial: no executable tool calls emitted in progress! Wave 4 reports
  // the whole argument text as `ToolArgumentsDelta` progress instead.
  progress1
  |> should.equal([message.ToolArgumentsDelta("call_calc_1", "{\"x\":42}")])

  // Finish with STOP
  let chunk2 =
    "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}"
  let assert Ok(#(reducer, progress2)) = google.step(reducer, event(chunk2))
  progress2
  |> should.equal([])

  let expected_call_id = "call_calc_1"
  let expected_tool_name = "calc"
  let expected_call =
    message.ToolCall(
      id: expected_call_id,
      name: expected_tool_name,
      arguments_json: "{\"x\":42}",
      provider_id: Some("call_calc_1"),
      provider_state: None,
    )

  google.terminal(reducer)
  |> should.equal(
    Some(stream_types.StreamFinished(
      outcome: stream_types.CompletedToolCallsWithData(
        text: "",
        calls: [expected_call],
        response_id: Some("resp_tools"),
        provider_data: encode_parts([
          "{\"functionCall\":{\"args\":{\"x\":42},\"id\":\"call_calc_1\",\"name\":\"calc\"}}",
        ]),
        issues: [],
      ),
      usage: None,
    )),
  )
}

pub fn google_tool_call_without_id_synthesizes_deterministic_id_test() {
  // `new_with_tools` is gone: the runtime admits calls at the terminal.
  let reducer = google.new(limits.default())

  // Legacy Gemini chunk without 'id' field in functionCall
  let chunk1 =
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":99}}}]}}]}"
  // Wave 4 reports the arguments as progress under the synthesized id.
  let assert Ok(#(reducer, [message.ToolArgumentsDelta("call_0", "{\"x\":99}")])) =
    google.step(reducer, event(chunk1))

  let chunk2 =
    "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}"
  let assert Ok(#(reducer, [])) = google.step(reducer, event(chunk2))

  let expected_call_id = "call_0"
  let expected_tool_name = "calc"
  let expected_call =
    message.ToolCall(
      id: expected_call_id,
      name: expected_tool_name,
      arguments_json: "{\"x\":99}",
      provider_id: None,
      provider_state: None,
    )

  google.terminal(reducer)
  |> should.equal(
    Some(stream_types.StreamFinished(
      outcome: stream_types.CompletedToolCallsWithData(
        text: "",
        calls: [expected_call],
        response_id: None,
        provider_data: encode_parts([
          "{\"functionCall\":{\"args\":{\"x\":99},\"name\":\"calc\"}}",
        ]),
        issues: [],
      ),
      usage: None,
    )),
  )
}

pub fn google_tool_call_duplicate_id_fails_test() {
  // `new_with_tools` is gone: the runtime admits calls at the terminal.
  let reducer = google.new(limits.default())

  let chunk =
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":1},\"id\":\"dup_id\"}},{\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":2},\"id\":\"dup_id\"}}]}}]}"
  case google.step(reducer, event(chunk)) {
    Error(error.Protocol(msg)) ->
      msg
      |> should.equal("Duplicate tool call id: dup_id")
    _ -> should.fail()
  }
}

pub fn google_safety_prompt_feedback_is_a_blocked_prompt_test() {
  let reducer = google.new(limits.default())

  let chunk =
    "{\"promptFeedback\":{\"blockReason\":\"SAFETY\",\"safetyRatings\":[{\"category\":\"HARM_CATEGORY_HATE_SPEECH\",\"probability\":\"HIGH\"}]}}"
  let assert Ok(#(reducer, [])) = google.step(reducer, event(chunk))

  let assert Some(stream_types.StreamFailed(error: problem, ..)) =
    google.terminal(reducer)
  problem |> should.equal(error.ContentFiltered(error.InPrompt, "SAFETY"))
}

pub fn google_filter_finish_reasons_are_content_filtered_test() {
  let reasons = [
    "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII",
    "IMAGE_SAFETY", "IMAGE_PROHIBITED_CONTENT",
  ]

  list_for_each(reasons, fn(reason) {
    let reducer = google.new(limits.default())
    let chunk =
      "{\"candidates\":[{\"finishReason\":\""
      <> reason
      <> "\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}"
    let assert Ok(#(reducer, [])) = google.step(reducer, event(chunk))
    let assert Some(stream_types.StreamFailed(error: problem, ..)) =
      google.terminal(reducer)
    problem |> should.equal(error.ContentFiltered(error.InOutput, reason))
  })
}

pub fn google_finish_reason_max_tokens_output_limited_test() {
  let reducer = google.new(limits.default())
  let chunk1 =
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Partial output\"}]}}]}"
  let assert Ok(#(reducer, _)) = google.step(reducer, event(chunk1))

  let chunk2 =
    "{\"candidates\":[{\"finishReason\":\"MAX_TOKENS\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}"
  let assert Ok(#(reducer, _)) = google.step(reducer, event(chunk2))

  google.terminal(reducer)
  |> should.equal(
    Some(stream_types.StreamFinished(
      outcome: stream_types.OutputLimited(
        partial_text: "Partial output",
        partial_calls: [],
      ),
      usage: None,
    )),
  )
}

pub fn google_top_level_error_payload_fails_test() {
  let reducer = google.new(limits.default())
  let chunk =
    "{\"error\":{\"code\":400,\"message\":\"API key not valid\",\"status\":\"INVALID_ARGUMENT\"}}"
  let assert Ok(#(reducer, [])) = google.step(reducer, event(chunk))

  google.terminal(reducer)
  |> should.equal(
    Some(stream_types.StreamFailed(
      error: error.Provider(
        code: Some("INVALID_ARGUMENT"),
        message: "API key not valid",
      ),
      retry: stream_types.RetryEvidence(
        stream_types.RequestMayHaveReachedProvider,
        True,
        False,
      ),
    )),
  )
}

pub fn google_request_encoding_messages_options_and_tools_test() {
  let config =
    google_options.new("test-goog-key")
    |> google_options.with_api_version("v1beta")
    |> google_options.config
    |> llm_wire.with_endpoint("http://127.0.0.1:8080/v1beta")
  let add = tool_fixtures.int_field_tool("add", "amount")

  let request =
    llm_wire.request("gemini-3.8-flash", [
      message.System("You are a helpful calculator assistant."),
      message.User("Add 5"),
    ])
    |> llm_wire.with_tools([add])
    |> llm_wire.with_max_tokens(512)
    |> llm_wire.with_temperature(0.5)
    |> llm_wire.with_top_p(0.9)
    |> llm_wire.with_stop_sequences(["END"])

  let assert Ok(prepared) = llm_wire.prepare(config, request)

  // Check path
  path(prepared)
  |> should.equal(
    "/v1beta/models/gemini-3.8-flash:streamGenerateContent?alt=sse",
  )

  // Check body structure
  let body = llm_wire.request_json(prepared)
  string.contains(
    body,
    "\"systemInstruction\":{\"parts\":[{\"text\":\"You are a helpful calculator assistant.\"}]}",
  )
  |> should.equal(True)
  string.contains(body, "\"role\":\"user\",\"parts\":[{\"text\":\"Add 5\"}]")
  |> should.equal(True)
  string.contains(body, "\"tools\":[{\"functionDeclarations\":[")
  |> should.equal(True)
  string.contains(body, "\"name\":\"add\"")
  |> should.equal(True)
  string.contains(body, "\"generationConfig\":{")
  |> should.equal(True)
  string.contains(body, "\"maxOutputTokens\":512")
  |> should.equal(True)
  string.contains(body, "\"temperature\":0.5")
  |> should.equal(True)
  string.contains(body, "\"topP\":0.9")
  |> should.equal(True)
  string.contains(body, "\"stopSequences\":[\"END\"]")
  |> should.equal(True)
}

pub fn google_function_declaration_uses_json_schema_profile_and_stop_limit_test() {
  let config = google_config("test-key", "http://127.0.0.1:8080")
  let shape =
    tool.new(
      "shape",
      "Shape input",
      tool_fixtures.one_field("values", codec.nullable(codec.list(codec.int()))),
    )
  let request =
    llm_wire.request("gemini-3.8-flash", [message.User("shape")])
    |> llm_wire.with_tools([shape])
    |> llm_wire.with_stop_sequences(["1", "2", "3", "4", "5"])
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  let body = llm_wire.request_json(prepared)
  string.contains(body, "\"parametersJsonSchema\":") |> should.equal(True)
  string.contains(body, "\"parameters\":") |> should.equal(False)
  string.contains(body, "\"additionalProperties\":false")
  |> should.equal(True)
  string.contains(body, "\"anyOf\":") |> should.equal(True)
  string.contains(body, "\"items\":") |> should.equal(True)
  string.contains(body, "\"stopSequences\":[\"1\",\"2\",\"3\",\"4\",\"5\"]")
  |> should.equal(True)

  let six_stops =
    llm_wire.with_stop_sequences(
      llm_wire.request("gemini-3.8-flash", [message.User("shape")]),
      ["1", "2", "3", "4", "5", "6"],
    )
  // The typed problem replaces the "at most 5" message.
  llm_wire.prepare(config, six_stops)
  |> should.equal(Error(error.InvalidRequest(error.TooManyStopSequences(5))))

  let number_limits = number.limits(64, 64, 64)
  let assert Ok(minimum) = number.parse("1", number_limits)
  let assert Ok(maximum) = number.parse("2", number_limits)
  let range = codec.number_between(minimum, maximum)
  let range_tool =
    tool.new("range", "Range input", tool_fixtures.one_field("value", range))
  let range_request =
    llm_wire.with_tools(
      llm_wire.request("gemini-3.8-flash", [message.User("range")]),
      [range_tool],
    )
  // The typed error names the tool whose schema Google cannot take.
  case llm_wire.prepare(config, range_request) {
    Error(error.UnsupportedSchema(error.ToolInput("range"), _)) ->
      should.be_true(True)
    _ -> should.fail()
  }
}

pub fn google_structured_output_sends_response_json_schema_with_nullable_test() {
  let config = google_config("test-key", "http://127.0.0.1:8080")
  let request = llm_wire.request("gemini-3.8-flash", [message.User("Extract")])

  let valid_codec = tool_fixtures.one_field("count", codec.int())
  let assert Ok(prepared) =
    llm_wire.prepare(
      config,
      request |> llm_wire.with_output("count_shape", valid_codec),
    )
  let body = llm_wire.request_json(prepared)
  string.contains(body, "\"responseMimeType\":\"application/json\"")
  |> should.equal(True)
  // The JSON Schema field: Gemini's OpenAPI `responseSchema` rejects
  // `additionalProperties` (live, 2026-10-04).
  string.contains(body, "\"responseJsonSchema\":{")
  |> should.equal(True)
  string.contains(body, "\"responseSchema\"")
  |> should.equal(False)

  // `codec.nullable` is sent as Blueprint's `anyOf` with `{"type": "null"}`,
  // which `responseJsonSchema` accepted live (2026-10-04, round 7).
  let nullable_codec =
    tool_fixtures.one_field("maybe_note", codec.nullable(codec.string()))
  let assert Ok(prepared) =
    llm_wire.prepare(
      config,
      request |> llm_wire.with_output("note_shape", nullable_codec),
    )
  llm_wire.request_json(prepared)
  |> string.contains(
    "\"maybe_note\":{\"anyOf\":[{\"type\":\"null\"},{\"type\":\"string\"}]}",
  )
  |> should.equal(True)
}

pub fn google_loopback_integration_text_stream_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)

    let chunks = [
      #(
        0,
        bit_array.from_string(
          "data: {\"responseId\":\"resp_stream_test\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hello \"}]}}]}\n\n",
        ),
      ),
      #(
        0,
        bit_array.from_string(
          "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Google!\"}]}}],\"usageMetadata\":{\"promptTokenCount\":4,\"candidatesTokenCount\":2,\"totalTokenCount\":6}}\n\n",
        ),
      ),
      #(
        0,
        bit_array.from_string(
          "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}\n\n",
        ),
      ),
    ]
    let _ = fake_server.send_sse_stream(socket, chunks, True)
    Nil
  })

  let config = loopback_config(server.port)
  let request = llm_wire.request("gemini-3.8-flash", [message.User("hi")])
  let assert Ok(prepared) = llm_wire.prepare(config, request)

  let assert Ok(llm_wire.Answer(text:, usage:, ..)) =
    llm_wire.run(owned_http, prepared)

  text |> should.equal("Hello Google!")
  usage |> should.equal(Some(message.Usage(4, 2, 6)))

  fake_server.stop(server)
}

pub fn google_loopback_integration_caller_owned_tool_round_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    // 1st request: return tool call
    let assert Ok(socket1) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers1) = fake_server.read_request_headers(socket1, 2000)

    let tool_chunks = [
      #(
        0,
        bit_array.from_string(
          "data: {\"responseId\":\"resp_call_1\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":7},\"id\":\"call_gemini_7\"},\"thoughtSignature\":\"opaque-state\"}]}}]}\n\n",
        ),
      ),
      #(
        0,
        bit_array.from_string(
          "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}\n\n",
        ),
      ),
    ]
    let _ = fake_server.send_sse_stream(socket1, tool_chunks, True)

    // 2nd request: verify caller-owned history and return final text
    let assert Ok(socket2) = fake_server.accept_connection(server, 2000)
    let assert Ok(_req2) = fake_server.read_request_headers(socket2, 2000)
    let answer_chunks = [
      #(
        0,
        bit_array.from_string(
          "data: {\"responseId\":\"resp_final\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"The answer is 14.\"}]}}]}\n\n",
        ),
      ),
      #(
        0,
        bit_array.from_string(
          "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}\n\n",
        ),
      ),
    ]
    let _ = fake_server.send_sse_stream(socket2, answer_chunks, True)
    Nil
  })

  let config = loopback_config(server.port)
  let calc = tool_fixtures.int_field_tool("calc", "x")

  let request =
    llm_wire.request("gemini-3.8-flash", [message.User("double 7")])
    |> llm_wire.with_tools([calc])

  let assert Ok(prepared) = llm_wire.prepare(config, request)

  // Run 1: returns tool call
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
    llm_wire.run(owned_http, prepared)

  let assert [first_call] = turn.calls
  first_call.arguments_json |> should.equal("{\"x\":7}")

  // Execute tool locally and append its result to the caller-owned history
  let tool_results = [#(first_call.id, "{\"result\":14}")]
  let assert Ok(continued_prepared) =
    llm_wire.prepare(
      config,
      conversation_fixture.append_results(request, turn, tool_results),
    )

  // Verify next request payload
  let cont_json = llm_wire.request_json(continued_prepared)
  string.contains(
    cont_json,
    "\"role\":\"model\",\"parts\":[{\"functionCall\":{\"args\":{\"x\":7},\"id\":\"call_gemini_7\",\"name\":\"calc\"},\"thoughtSignature\":\"opaque-state\"}]",
  )
  |> should.equal(True)
  string.contains(
    cont_json,
    "\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"name\":\"calc\",\"response\":{\"result\":14},\"id\":\"call_gemini_7\"}}]",
  )
  |> should.equal(True)

  // Run 2: returns final text
  let assert Ok(llm_wire.Answer(text: answer, ..)) =
    llm_wire.run(owned_http, continued_prepared)

  answer |> should.equal("The answer is 14.")
  fake_server.stop(server)
}

pub fn google_loopback_integration_blocked_prompt_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers) = fake_server.read_request_headers(socket, 2000)

    let chunks = [
      #(
        0,
        bit_array.from_string(
          "data: {\"promptFeedback\":{\"blockReason\":\"SAFETY\"}}\n\n",
        ),
      ),
    ]
    let _ = fake_server.send_sse_stream(socket, chunks, True)
    Nil
  })

  let config = loopback_config(server.port)
  let request =
    llm_wire.request("gemini-3.8-flash", [message.User("harmful query")])
  let assert Ok(prepared) = llm_wire.prepare(config, request)

  let assert Error(failure) = llm_wire.run(owned_http, prepared)

  failure.error
  |> should.equal(error.ContentFiltered(error.InPrompt, "SAFETY"))
  failure.sent |> should.equal(llm_wire.Completed)
  fake_server.stop(server)
}

pub fn google_missing_provider_id_is_omitted_from_next_request_test() {
  use owned_http <- http_test_helpers.with_client
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    let assert Ok(socket1) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers1) = fake_server.read_request_headers(socket1, 2000)
    let first = [
      #(
        0,
        bit_array.from_string(
          "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":7}}}]}}]}\n\n",
        ),
      ),
      #(
        0,
        bit_array.from_string(
          "data: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[]}}]}\n\n",
        ),
      ),
    ]
    let _ = fake_server.send_sse_stream(socket1, first, True)
    let assert Ok(socket2) = fake_server.accept_connection(server, 2000)
    let assert Ok(req2) = fake_server.read_request_headers(socket2, 2000)
    let valid =
      string.contains(req2, "\"functionResponse\":{\"name\":\"calc\"")
      && !string.contains(
        req2,
        "\"functionResponse\":{\"name\":\"calc\",\"response\":{\"result\":14},\"id\"",
      )
    let answer = case valid {
      True -> [
        #(
          0,
          bit_array.from_string(
            "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"ok\"}]}}]}\n\ndata: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[]}}]}\n\n",
          ),
        ),
      ]
      False -> [
        #(
          0,
          bit_array.from_string(
            "data: {\"error\":{\"code\":400,\"message\":\"id leaked\"}}\n\n",
          ),
        ),
      ]
    }
    let _ = fake_server.send_sse_stream(socket2, answer, True)
    Nil
  })

  let config = loopback_config(server.port)
  let calc = tool_fixtures.int_field_tool("calc", "x")
  let request =
    llm_wire.request("gemini-3.8-flash", [message.User("double 7")])
    |> llm_wire.with_tools([calc])
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) =
    llm_wire.run(owned_http, prepared)
  let assert [first_call] = turn.calls
  first_call.id |> should.equal("call_0")
  let assert Ok(next) =
    llm_wire.prepare(
      config,
      conversation_fixture.append_results(request, turn, [
        #(first_call.id, "{\"result\":14}"),
      ]),
    )
  let body = llm_wire.request_json(next)
  string.contains(
    body,
    "\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":7}}",
  )
  |> should.equal(True)
  string.contains(
    body,
    "\"functionResponse\":{\"name\":\"calc\",\"response\":{\"result\":14}}",
  )
  |> should.equal(True)
  string.contains(body, "call_0") |> should.equal(False)
  let assert Ok(llm_wire.Answer(text:, ..)) = llm_wire.run(owned_http, next)
  text |> should.equal("ok")
  fake_server.stop(server)
}

fn list_for_each(items: List(a), f: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [first, ..rest] -> {
      f(first)
      list_for_each(rest, f)
    }
  }
}

pub fn google_gemini_thought_signature_is_preserved_in_assistant_data_test() {
  // `new_with_tools` is gone: the runtime admits calls at the terminal.
  let reducer = google.new(limits.default())
  let payload =
    "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"id\":\"call_1\",\"args\":{\"x\":1}},\"thoughtSignature\":\"opaque\"}]}}]}"
  let assert Ok(#(reducer, _)) = google.step(reducer, event(payload))
  let call_id = "call_1"
  let tool_name = "calc"
  google.terminal(reducer)
  |> should.equal(
    Some(stream_types.StreamFinished(
      outcome: stream_types.CompletedToolCallsWithData(
        text: "",
        calls: [
          message.ToolCall(
            id: call_id,
            name: tool_name,
            arguments_json: "{\"x\":1}",
            provider_id: Some("call_1"),
            provider_state: Some("opaque"),
          ),
        ],
        response_id: None,
        provider_data: encode_parts([
          "{\"functionCall\":{\"args\":{\"x\":1},\"id\":\"call_1\",\"name\":\"calc\"},\"thoughtSignature\":\"opaque\"}",
        ]),
        issues: [],
      ),
      usage: None,
    )),
  )
}

pub fn google_signed_non_tool_parts_are_retained_in_order_test() {
  // `new_with_tools` is gone: the runtime admits calls at the terminal.
  let reducer = google.new(limits.default())
  let payload =
    "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[{\"text\":\"thinking\",\"thoughtSignature\":\"text-sig\"},{\"functionCall\":{\"name\":\"calc\",\"id\":\"call_1\",\"args\":{\"x\":1}},\"thoughtSignature\":\"call-sig\"}]}}]}"
  let assert Ok(#(reducer, _)) = google.step(reducer, event(payload))
  case google.terminal(reducer) {
    Some(stream_types.StreamFinished(
      stream_types.CompletedToolCallsWithData(_, _, _, saved_parts, []),
      _,
    )) -> {
      let assert Ok([text_part, call_part]) =
        json.parse(saved_parts, decode.list(decode.string))
      text_part
      |> string.contains("\"thoughtSignature\":\"text-sig\"")
      |> should.be_true
      call_part
      |> string.contains("\"thoughtSignature\":\"call-sig\"")
      |> should.be_true
    }
    _ -> should.fail()
  }
}

pub fn google_malformed_thought_signature_is_a_typed_protocol_error_test() {
  let reducer = google.new(limits.default())
  let payload =
    "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"thinking\",\"thoughtSignature\":7}]}}]}"
  case google.step(reducer, event(payload)) {
    Error(error.Protocol(detail)) ->
      detail |> string.contains("thoughtSignature") |> should.be_true
    _ -> should.fail()
  }
}

pub fn google_tool_call_outside_the_name_grammar_is_a_protocol_error_test() {
  // `new_with_tools` is gone: the runtime admits calls at the terminal.
  let reducer = google.new(limits.default())
  let chunk =
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"default_api.calc\",\"args\":{\"x\":1},\"id\":\"call_dot\"}}]}}]}"
  case google.step(reducer, event(chunk)) {
    Error(error.Protocol(detail)) ->
      string.contains(detail, "invalid tool name") |> should.be_true
    _ -> should.fail()
  }
}

fn encode_parts(parts: List(String)) -> String {
  json.array(parts, json.string) |> json.to_string
}
