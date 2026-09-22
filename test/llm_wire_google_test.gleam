import fake_server
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import json/blueprint/codec
import json/blueprint/number
import llm_wire/api
import llm_wire/google
import llm_wire/runtime
import llm_wire/sse
import llm_wire/types
import tool_fixtures

fn event(data: String) -> sse.ServerSentEvent {
  sse.ServerSentEvent(event: None, data: data, id: None, retry: None)
}

pub fn google_text_streaming_and_stop_completion_test() {
  let reducer = google.new(types.default_limits())

  // Chunk 1: text delta + responseId
  let chunk1 =
    "{\"responseId\":\"resp_123\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hello \"}]}}]}"
  let assert Ok(#(reducer, progress1)) = google.step(reducer, event(chunk1))
  progress1
  |> should.equal([types.TextDelta(block_id: "0", text: "Hello ")])

  // Chunk 2: text delta + usageMetadata
  let chunk2 =
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"world!\"}]}}],\"usageMetadata\":{\"promptTokenCount\":5,\"candidatesTokenCount\":3,\"totalTokenCount\":8}}"
  let assert Ok(#(reducer, progress2)) = google.step(reducer, event(chunk2))
  progress2
  |> should.equal([
    types.UsageUpdate(types.Usage(5, 3, 8)),
    types.TextDelta(block_id: "0", text: "world!"),
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
    Some(types.StreamFinished(
      outcome: types.CompletedText("Hello world!"),
      usage: Some(types.Usage(5, 3, 8)),
    )),
  )
}

pub fn google_tool_call_buffering_and_completion_test() {
  let tool = tool_fixtures.int_field_tool("calc", "x")
  let assert Ok(reducer) = google.new_with_tools(types.default_limits(), [tool])

  // Tool call chunk with ID
  let chunk1 =
    "{\"responseId\":\"resp_tools\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":42},\"id\":\"call_calc_1\"}}]}}]}"
  let assert Ok(#(reducer, progress1)) = google.step(reducer, event(chunk1))
  // Crucial: no executable tool calls emitted in progress!
  progress1
  |> should.equal([])

  // Finish with STOP
  let chunk2 =
    "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}"
  let assert Ok(#(reducer, progress2)) = google.step(reducer, event(chunk2))
  progress2
  |> should.equal([])

  let assert Ok(expected_call_id) = types.call_id("call_calc_1")
  let assert Ok(expected_tool_name) = types.tool_name("calc")
  let expected_call =
    types.ToolCall(
      id: expected_call_id,
      name: expected_tool_name,
      arguments_json: "{\"x\":42}",
      provider_id: Some("call_calc_1"),
    )

  google.terminal(reducer)
  |> should.equal(
    Some(types.StreamFinished(
      outcome: types.CompletedToolCalls(
        text: "",
        calls: [expected_call],
        response_id: Some("resp_tools"),
      ),
      usage: None,
    )),
  )
}

pub fn google_tool_call_without_id_synthesizes_deterministic_id_test() {
  let tool = tool_fixtures.int_field_tool("calc", "x")
  let assert Ok(reducer) = google.new_with_tools(types.default_limits(), [tool])

  // Legacy Gemini chunk without 'id' field in functionCall
  let chunk1 =
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":99}}}]}}]}"
  let assert Ok(#(reducer, [])) = google.step(reducer, event(chunk1))

  let chunk2 =
    "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}"
  let assert Ok(#(reducer, [])) = google.step(reducer, event(chunk2))

  let assert Ok(expected_call_id) = types.call_id("call_0")
  let assert Ok(expected_tool_name) = types.tool_name("calc")
  let expected_call =
    types.ToolCall(
      id: expected_call_id,
      name: expected_tool_name,
      arguments_json: "{\"x\":99}",
      provider_id: None,
    )

  google.terminal(reducer)
  |> should.equal(
    Some(types.StreamFinished(
      outcome: types.CompletedToolCalls(
        text: "",
        calls: [expected_call],
        response_id: None,
      ),
      usage: None,
    )),
  )
}

pub fn google_tool_call_duplicate_id_fails_test() {
  let tool = tool_fixtures.int_field_tool("calc", "x")
  let assert Ok(reducer) = google.new_with_tools(types.default_limits(), [tool])

  let chunk =
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":1},\"id\":\"dup_id\"}},{\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":2},\"id\":\"dup_id\"}}]}}]}"
  case google.step(reducer, event(chunk)) {
    Error(types.ProtocolError(msg)) ->
      msg
      |> should.equal("Duplicate tool call id: dup_id")
    _ -> should.fail()
  }
}

pub fn google_tool_call_argument_type_mismatch_fails_test() {
  let tool = tool_fixtures.int_field_tool("calc", "x")
  let assert Ok(reducer) = google.new_with_tools(types.default_limits(), [tool])

  // Tool expects integer for 'x', but string is passed
  let chunk1 =
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":\"string_val\"},\"id\":\"call_type_err\"}}]}}]}"
  let assert Ok(#(reducer, [])) = google.step(reducer, event(chunk1))

  // Finish reason triggers tool catalog validation
  let chunk2 =
    "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}"
  case google.step(reducer, event(chunk2)) {
    Error(types.ProtocolError(msg)) ->
      string.contains(msg, "failed schema validation")
      |> should.equal(True)
    _ -> should.fail()
  }
}

pub fn google_tool_call_undeclared_name_fails_test() {
  let tool = tool_fixtures.int_field_tool("calc", "x")
  let assert Ok(reducer) = google.new_with_tools(types.default_limits(), [tool])

  let chunk1 =
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"unregistered_tool\",\"args\":{},\"id\":\"call_unreg\"}}]}}]}"
  let assert Ok(#(reducer, [])) = google.step(reducer, event(chunk1))

  let chunk2 =
    "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}"
  case google.step(reducer, event(chunk2)) {
    Error(types.ProtocolError(msg)) ->
      string.contains(msg, "Tool not declared in admitted catalog")
      |> should.equal(True)
    _ -> should.fail()
  }
}

pub fn google_safety_prompt_feedback_refused_test() {
  let reducer = google.new(types.default_limits())

  let chunk =
    "{\"promptFeedback\":{\"blockReason\":\"SAFETY\",\"safetyRatings\":[{\"category\":\"HARM_CATEGORY_HATE_SPEECH\",\"probability\":\"HIGH\"}]}}"
  let assert Ok(#(reducer, [])) = google.step(reducer, event(chunk))

  google.terminal(reducer)
  |> should.equal(
    Some(types.StreamFinished(
      outcome: types.Refused("Prompt blocked by safety policy: SAFETY"),
      usage: None,
    )),
  )
}

pub fn google_finish_reason_refusal_test() {
  let reasons = [
    #("SAFETY", "Google refused generation with reason: SAFETY"),
    #("RECITATION", "Google refused generation with reason: RECITATION"),
    #("BLOCKLIST", "Google refused generation with reason: BLOCKLIST"),
    #(
      "PROHIBITED_CONTENT",
      "Google refused generation with reason: PROHIBITED_CONTENT",
    ),
    #("SPII", "Google refused generation with reason: SPII"),
  ]

  list_for_each(reasons, fn(pair) {
    let #(reason, expected_refusal) = pair
    let reducer = google.new(types.default_limits())
    let chunk =
      "{\"candidates\":[{\"finishReason\":\""
      <> reason
      <> "\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}"
    let assert Ok(#(reducer, [])) = google.step(reducer, event(chunk))
    google.terminal(reducer)
    |> should.equal(
      Some(types.StreamFinished(
        outcome: types.Refused(expected_refusal),
        usage: None,
      )),
    )
  })
}

pub fn google_finish_reason_max_tokens_output_limited_test() {
  let reducer = google.new(types.default_limits())
  let chunk1 =
    "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Partial output\"}]}}]}"
  let assert Ok(#(reducer, _)) = google.step(reducer, event(chunk1))

  let chunk2 =
    "{\"candidates\":[{\"finishReason\":\"MAX_TOKENS\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}"
  let assert Ok(#(reducer, _)) = google.step(reducer, event(chunk2))

  google.terminal(reducer)
  |> should.equal(
    Some(types.StreamFinished(
      outcome: types.OutputLimited(
        partial_text: "Partial output",
        partial_calls: [],
      ),
      usage: None,
    )),
  )
}

pub fn google_top_level_error_payload_fails_test() {
  let reducer = google.new(types.default_limits())
  let chunk =
    "{\"error\":{\"code\":400,\"message\":\"API key not valid\",\"status\":\"INVALID_ARGUMENT\"}}"
  let assert Ok(#(reducer, [])) = google.step(reducer, event(chunk))

  google.terminal(reducer)
  |> should.equal(
    Some(types.StreamFailed(
      error: types.ProviderError(
        code: Some("INVALID_ARGUMENT"),
        message: "API key not valid",
      ),
      retry: types.RetryEvidence(
        types.RequestMayHaveReachedProvider,
        True,
        False,
      ),
    )),
  )
}

pub fn google_request_encoding_messages_options_and_tools_test() {
  let assert Ok(api_key) = types.api_key("test-goog-key")
  let assert Ok(endpoint) = types.endpoint("http://127.0.0.1:8080/v1beta")
  let config = types.google_config(api_key, endpoint, Some("v1beta"))
  let assert Ok(model) = types.model_id("gemini-2.5-flash")
  let tool = tool_fixtures.int_field_tool("add", "amount")

  let request =
    types.new_request(model, [
      types.SystemMessage("You are a helpful calculator assistant."),
      types.UserMessage("Add 5"),
    ])
    |> types.with_tools([tool])
    |> types.with_max_tokens(512)
    |> types.with_temperature(0.5)
    |> types.with_top_p(0.9)
    |> types.with_stop_sequences(["END"])

  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())

  // Check path
  api.prepared_path(prepared)
  |> should.equal(
    "/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse",
  )

  // Check body structure
  let body = api.prepared_request_json(prepared)
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
  let assert Ok(api_key) = types.api_key("test-key")
  let assert Ok(endpoint) = types.endpoint("http://127.0.0.1:8080")
  let config = types.google_config(api_key, endpoint, None)
  let assert Ok(model) = types.model_id("gemini-2.5-flash")
  let assert Ok(tool_name) = types.tool_name("shape")
  let assert Ok(tool) =
    types.tool_from_codec(
      tool_name,
      "Shape input",
      codec.object(codec.required(
        "values",
        codec.nullable(codec.list(codec.int())),
      )),
    )
  let request =
    types.new_request(model, [types.UserMessage("shape")])
    |> types.with_tools([tool])
    |> types.with_stop_sequences(["1", "2", "3", "4", "5"])
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  let body = api.prepared_request_json(prepared)
  string.contains(body, "\"parametersJsonSchema\":") |> should.equal(True)
  string.contains(body, "\"parameters\":") |> should.equal(False)
  string.contains(body, "\"additionalProperties\":false")
  |> should.equal(True)
  string.contains(body, "\"anyOf\":") |> should.equal(True)
  string.contains(body, "\"items\":") |> should.equal(True)
  string.contains(body, "\"stopSequences\":[\"1\",\"2\",\"3\",\"4\",\"5\"]")
  |> should.equal(True)

  let six_stops =
    types.with_stop_sequences(
      types.new_request(model, [types.UserMessage("shape")]),
      ["1", "2", "3", "4", "5", "6"],
    )
  case api.prepare(config, six_stops, types.default_limits()) {
    Error(types.PreparationError(message)) ->
      string.contains(message, "at most 5") |> should.equal(True)
    _ -> should.fail()
  }

  let assert Ok(number_limits) = number.number_limits(64, 64, 64)
  let assert Ok(minimum) = number.parse_number(number_limits, "1")
  let assert Ok(maximum) = number.parse_number(number_limits, "2")
  let assert Ok(range) = codec.number_between(minimum, maximum)
  let assert Ok(range_name) = types.tool_name("range")
  let assert Ok(range_tool) =
    types.tool_from_codec(
      range_name,
      "Range input",
      codec.field("value", range),
    )
  let range_request =
    types.with_tools(types.new_request(model, [types.UserMessage("range")]), [
      range_tool,
    ])
  case api.prepare(config, range_request, types.default_limits()) {
    Error(types.PreparationError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn google_structured_output_accepts_valid_schema_and_rejects_nullable_test() {
  let assert Ok(api_key) = types.api_key("test-key")
  let assert Ok(endpoint) = types.endpoint("http://127.0.0.1:8080")
  let config = types.google_config(api_key, endpoint, None)
  let assert Ok(model) = types.model_id("gemini-2.5-flash")
  let request = types.new_request(model, [types.UserMessage("Extract")])

  // Valid non-nullable schema: should succeed
  let valid_codec = codec.object(codec.required("count", codec.int()))
  case
    api.prepare_structured(
      config,
      request,
      types.default_limits(),
      "count_shape",
      valid_codec,
    )
  {
    Ok(prep) -> {
      let body = api.structured_request_json(prep)
      string.contains(body, "\"responseMimeType\":\"application/json\"")
      |> should.equal(True)
      string.contains(body, "\"responseSchema\":{")
      |> should.equal(True)
    }
    _ -> should.fail()
  }

  // Nullable schema: Google Gemini responseSchema does not admit anyOf / nullables, must be rejected
  let invalid_codec =
    codec.object(codec.required("maybe_note", codec.nullable(codec.string())))
  case
    api.prepare_structured(
      config,
      request,
      types.default_limits(),
      "note_shape",
      invalid_codec,
    )
  {
    Error(types.PreparationError(msg)) ->
      string.contains(
        msg,
        "Google structured output does not support nullable/anyOf schema",
      )
      |> should.equal(True)
    _ -> should.fail()
  }
}

pub fn google_loopback_integration_text_stream_test() {
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

  let assert Ok(key) = types.api_key("sk-local-google")
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(server.port))
  let assert Ok(model) = types.model_id("gemini-2.5-flash")
  let config = types.google_config(key, endpoint, None)
  let request = types.new_request(model, [types.UserMessage("hi")])
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())

  let assert Ok(api.RunText(text, usage)) =
    runtime.run(prepared, types.default_limits(), types.default_deadlines())

  text |> should.equal("Hello Google!")
  usage |> should.equal(Some(types.Usage(4, 2, 6)))

  fake_server.stop(server)
}

pub fn google_loopback_integration_tool_continuation_test() {
  let assert Ok(server) = fake_server.start()
  process.spawn_unlinked(fn() {
    // 1st request: return tool call
    let assert Ok(socket1) = fake_server.accept_connection(server, 2000)
    let assert Ok(_headers1) = fake_server.read_request_headers(socket1, 2000)

    let tool_chunks = [
      #(
        0,
        bit_array.from_string(
          "data: {\"responseId\":\"resp_call_1\",\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":7},\"id\":\"call_gemini_7\"}}]}}]}\n\n",
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

    // 2nd request: verify continuation body and return final text
    let assert Ok(socket2) = fake_server.accept_connection(server, 2000)
    let assert Ok(req2) = fake_server.read_request_headers(socket2, 2000)

    let has_fr =
      string.contains(
        req2,
        "\"functionResponse\":{\"name\":\"calc\",\"response\":{\"result\":14},\"id\":\"call_gemini_7\"}",
      )

    let answer_chunks = case has_fr {
      True -> [
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
      False -> [
        #(
          0,
          bit_array.from_string(
            "data: {\"error\":{\"code\":400,\"message\":\"missing functionResponse\"}}\n\n",
          ),
        ),
      ]
    }
    let _ = fake_server.send_sse_stream(socket2, answer_chunks, True)
    Nil
  })

  let assert Ok(key) = types.api_key("sk-local-google")
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(server.port))
  let assert Ok(model) = types.model_id("gemini-2.5-flash")
  let config = types.google_config(key, endpoint, None)
  let tool = tool_fixtures.int_field_tool("calc", "x")

  let request =
    types.new_request(model, [types.UserMessage("double 7")])
    |> types.with_tools([tool])

  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())

  // Run 1: returns tool call
  let assert Ok(api.RunToolCalls(calls, continuation, _)) =
    runtime.run(prepared, types.default_limits(), types.default_deadlines())

  let assert [call] = calls
  call.arguments_json |> should.equal("{\"x\":7}")

  // Execute tool locally and prepare continuation
  let tool_results = [types.ToolResult(call.id, "{\"result\":14}")]
  let assert Ok(continued_prepared) =
    api.prepare_continue(
      prepared,
      continuation,
      tool_results,
      types.default_limits(),
    )

  // Verify continuation payload
  let cont_json = api.prepared_request_json(continued_prepared)
  string.contains(
    cont_json,
    "\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"args\":{\"x\":7},\"id\":\"call_gemini_7\"}}]",
  )
  |> should.equal(True)
  string.contains(
    cont_json,
    "\"role\":\"user\",\"parts\":[{\"functionResponse\":{\"name\":\"calc\",\"response\":{\"result\":14},\"id\":\"call_gemini_7\"}}]",
  )
  |> should.equal(True)

  // Run 2: returns final text
  let assert Ok(api.RunText(answer, _)) =
    runtime.run(
      continued_prepared,
      types.default_limits(),
      types.default_deadlines(),
    )

  answer |> should.equal("The answer is 14.")
  fake_server.stop(server)
}

pub fn google_loopback_integration_refusal_test() {
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

  let assert Ok(key) = types.api_key("sk-local-google")
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(server.port))
  let assert Ok(model) = types.model_id("gemini-2.5-flash")
  let config = types.google_config(key, endpoint, None)
  let request = types.new_request(model, [types.UserMessage("harmful query")])
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())

  let assert Ok(api.RunRefusal(reason)) =
    runtime.run(prepared, types.default_limits(), types.default_deadlines())

  reason |> should.equal("Prompt blocked by safety policy: SAFETY")
  fake_server.stop(server)
}

pub fn google_missing_provider_id_is_omitted_from_continuation_test() {
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

  let assert Ok(key) = types.api_key("sk-local-google")
  let assert Ok(endpoint) =
    types.endpoint("http://127.0.0.1:" <> int.to_string(server.port))
  let assert Ok(model) = types.model_id("gemini-2.5-flash")
  let config = types.google_config(key, endpoint, None)
  let tool = tool_fixtures.int_field_tool("calc", "x")
  let request =
    types.new_request(model, [types.UserMessage("double 7")])
    |> types.with_tools([tool])
  let assert Ok(prepared) = api.prepare(config, request, types.default_limits())
  let assert Ok(api.RunToolCalls([call], continuation, _)) =
    runtime.run(prepared, types.default_limits(), types.default_deadlines())
  call.id |> types.call_id_to_string |> should.equal("call_0")
  let assert Ok(next) =
    api.prepare_continue(
      prepared,
      continuation,
      [types.ToolResult(call.id, "{\"result\":14}")],
      types.default_limits(),
    )
  let body = api.prepared_request_json(next)
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
  let assert Ok(api.RunText(text, _)) =
    runtime.run(next, types.default_limits(), types.default_deadlines())
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

pub fn google_gemini_thought_signature_is_not_silently_dropped_test() {
  let tool = tool_fixtures.int_field_tool("calc", "x")
  let assert Ok(reducer) = google.new_with_tools(types.default_limits(), [tool])
  let payload =
    "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"id\":\"call_1\",\"args\":{\"x\":1}},\"thoughtSignature\":\"opaque\"}]}}]}"
  case google.step(reducer, event(payload)) {
    Error(types.ProtocolError(message)) ->
      string.contains(message, "thoughtSignature")
      |> should.equal(True)
    _ -> should.fail()
  }
}
