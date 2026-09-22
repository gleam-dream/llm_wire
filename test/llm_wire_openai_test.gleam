import gleam/option.{None, Some}
import gleeunit/should
import llm_wire/openai
import llm_wire/sse
import llm_wire/types
import tool_fixtures

fn event(name: String, data: String) -> sse.ServerSentEvent {
  sse.ServerSentEvent(event: Some(name), data: data, id: None, retry: None)
}

pub fn openai_refusal_delta_is_reduced_and_terminally_refused_test() {
  let reducer = openai.new(types.default_limits())
  let assert Ok(#(reducer, [])) =
    openai.step(
      reducer,
      event(
        "response.output_item.added",
        "{\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\"}}",
      ),
    )
  let assert Ok(#(reducer, refusal_progress)) =
    openai.step(
      reducer,
      event(
        "response.refusal.delta",
        "{\"output_index\":0,\"item_id\":\"msg_1\",\"delta\":\"I cannot help with that.\"}",
      ),
    )
  refusal_progress
  |> should.equal([
    types.RefusalDelta(block_id: "msg_1", text: "I cannot help with that."),
  ])
  let assert Ok(#(reducer, [])) =
    openai.step(
      reducer,
      event(
        "response.output_item.done",
        "{\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\"}}",
      ),
    )
  let assert Ok(#(reducer, _)) =
    openai.step(
      reducer,
      event(
        "response.completed",
        "{\"response\":{\"id\":\"resp_refusal\",\"status\":\"completed\"}}",
      ),
    )
  openai.terminal(reducer)
  |> should.equal(
    Some(types.StreamFinished(
      outcome: types.Refused("I cannot help with that."),
      usage: None,
    )),
  )
}

pub fn openai_reasoning_summary_delta_is_routed_and_completed_test() {
  let reducer = openai.new(types.default_limits())
  let assert Ok(#(reducer, [])) =
    openai.step(
      reducer,
      event(
        "response.output_item.added",
        "{\"output_index\":2,\"item\":{\"id\":\"reason_1\",\"type\":\"reasoning\"}}",
      ),
    )
  let assert Ok(#(reducer, progress)) =
    openai.step(
      reducer,
      event(
        "response.reasoning_summary_text.delta",
        "{\"output_index\":2,\"item_id\":\"reason_1\",\"delta\":\"Checking the result.\"}",
      ),
    )
  progress
  |> should.equal([
    types.ReasoningDelta(block_id: "reason_1", text: "Checking the result."),
  ])
  let assert Ok(#(reducer, [])) =
    openai.step(
      reducer,
      event(
        "response.output_item.done",
        "{\"output_index\":2,\"item\":{\"id\":\"reason_1\",\"type\":\"reasoning\"}}",
      ),
    )
  let assert Ok(#(reducer, _)) =
    openai.step(
      reducer,
      event(
        "response.completed",
        "{\"response\":{\"id\":\"resp_reason\",\"status\":\"completed\"}}",
      ),
    )
  openai.terminal(reducer)
  |> should.equal(
    Some(types.StreamFinished(outcome: types.CompletedText(""), usage: None)),
  )
}

pub fn openai_incomplete_reasoning_item_cannot_complete_response_test() {
  let reducer = openai.new(types.default_limits())
  let assert Ok(#(reducer, [])) =
    openai.step(
      reducer,
      event(
        "response.output_item.added",
        "{\"output_index\":0,\"item\":{\"id\":\"reason_1\",\"type\":\"reasoning\"}}",
      ),
    )
  let result =
    openai.step(
      reducer,
      event(
        "response.completed",
        "{\"response\":{\"id\":\"resp_reason\",\"status\":\"completed\"}}",
      ),
    )
  result |> should.be_error
}

pub fn openai_refusal_cannot_arrive_after_message_completion_test() {
  let reducer = openai.new(types.default_limits())
  let assert Ok(#(reducer, [])) =
    openai.step(
      reducer,
      event(
        "response.output_item.added",
        "{\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\"}}",
      ),
    )
  let assert Ok(#(reducer, [])) =
    openai.step(
      reducer,
      event(
        "response.output_item.done",
        "{\"output_index\":0,\"item\":{\"id\":\"msg_1\"}}",
      ),
    )
  openai.step(
    reducer,
    event(
      "response.refusal.delta",
      "{\"output_index\":0,\"item_id\":\"msg_1\",\"delta\":\"late\"}",
    ),
  )
  |> should.be_error
}

pub fn openai_text_cannot_arrive_after_message_completion_test() {
  let reducer = openai.new(types.default_limits())
  let assert Ok(#(reducer, [])) =
    openai.step(
      reducer,
      event(
        "response.output_item.added",
        "{\"output_index\":0,\"item\":{\"id\":\"msg_1\",\"type\":\"message\"}}",
      ),
    )
  let assert Ok(#(reducer, [])) =
    openai.step(
      reducer,
      event(
        "response.output_item.done",
        "{\"output_index\":0,\"item\":{\"id\":\"msg_1\"}}",
      ),
    )
  openai.step(
    reducer,
    event(
      "response.output_text.delta",
      "{\"output_index\":0,\"item_id\":\"msg_1\",\"delta\":\"late\"}",
    ),
  )
  |> should.be_error
}

pub fn openai_text_stream_test() {
  let reducer = openai.new(types.default_limits())

  // response.created
  let ev1 =
    sse.ServerSentEvent(
      event: Some("response.created"),
      data: "{\"response\": {\"id\": \"resp_1\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, progress1)) = openai.step(reducer, ev1)
  progress1 |> should.equal([])

  // output_item.added (message)
  let ev2 =
    sse.ServerSentEvent(
      event: Some("response.output_item.added"),
      data: "{\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\", \"role\": \"assistant\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, progress2)) = openai.step(reducer, ev2)
  progress2 |> should.equal([])

  // text delta
  let ev3 =
    sse.ServerSentEvent(
      event: Some("response.output_text.delta"),
      data: "{\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"Hello \"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, progress3)) = openai.step(reducer, ev3)
  progress3
  |> should.equal([types.TextDelta(block_id: "item_1", text: "Hello ")])

  // second text delta
  let ev4 =
    sse.ServerSentEvent(
      event: Some("response.output_text.delta"),
      data: "{\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"world!\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, progress4)) = openai.step(reducer, ev4)
  progress4
  |> should.equal([types.TextDelta(block_id: "item_1", text: "world!")])

  // output_item.done
  let ev_done =
    sse.ServerSentEvent(
      event: Some("response.output_item.done"),
      data: "{\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\", \"role\": \"assistant\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, progress_done)) = openai.step(reducer, ev_done)
  progress_done |> should.equal([])

  // response.completed
  let ev5 =
    sse.ServerSentEvent(
      event: Some("response.completed"),
      data: "{\"response\": {\"id\": \"resp_1\", \"status\": \"completed\", \"usage\": {\"input_tokens\": 10, \"output_tokens\": 5, \"total_tokens\": 15}}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, progress5)) = openai.step(reducer, ev5)
  progress5
  |> should.equal([
    types.UsageUpdate(types.Usage(
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
    )),
  ])

  openai.terminal(reducer)
  |> should.equal(
    Some(types.StreamFinished(
      outcome: types.CompletedText("Hello world!"),
      usage: Some(types.Usage(
        input_tokens: 10,
        output_tokens: 5,
        total_tokens: 15,
      )),
    )),
  )
}

pub fn openai_interleaved_tool_calls_test() {
  let tool = tool_fixtures.string_field_tool("get_weather", "city")
  let assert Ok(reducer) = openai.new_with_tools(types.default_limits(), [tool])

  // Add tool call 1: item_1, index 0, call_id "call_weather_1"
  let ev1 =
    sse.ServerSentEvent(
      event: Some("response.output_item.added"),
      data: "{\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"function_call\", \"call_id\": \"call_weather_1\", \"name\": \"get_weather\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev1)

  // Add tool call 2: item_2, index 1, call_id "call_weather_2" (same tool name!)
  let ev2 =
    sse.ServerSentEvent(
      event: Some("response.output_item.added"),
      data: "{\"output_index\": 1, \"item\": {\"id\": \"item_2\", \"type\": \"function_call\", \"call_id\": \"call_weather_2\", \"name\": \"get_weather\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev2)

  // Interleaved argument deltas: chunk for call 2 first!
  let ev3 =
    sse.ServerSentEvent(
      event: Some("response.function_call_arguments.delta"),
      data: "{\"output_index\": 1, \"item_id\": \"item_2\", \"delta\": \"{\\\"city\\\": \\\"Paris\\\"}\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev3)

  // Then chunk for call 1
  let ev4 =
    sse.ServerSentEvent(
      event: Some("response.function_call_arguments.delta"),
      data: "{\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"{\\\"city\\\": \\\"Tokyo\\\"}\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev4)

  // Done for call 1
  let ev5 =
    sse.ServerSentEvent(
      event: Some("response.output_item.done"),
      data: "{\"output_index\": 0, \"item\": {\"id\": \"item_1\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p5)) = openai.step(reducer, ev5)
  let assert Ok(expected_call_id1) = types.call_id("call_weather_1")
  let assert Ok(expected_tool_name) = types.tool_name("get_weather")
  p5 |> should.equal([])

  // Done for call 2
  let ev6 =
    sse.ServerSentEvent(
      event: Some("response.output_item.done"),
      data: "{\"output_index\": 1, \"item\": {\"id\": \"item_2\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p6)) = openai.step(reducer, ev6)
  let assert Ok(expected_call_id2) = types.call_id("call_weather_2")
  p6 |> should.equal([])

  // Response completed
  let ev7 =
    sse.ServerSentEvent(
      event: Some("response.completed"),
      data: "{\"response\": {\"id\": \"resp_1\", \"status\": \"completed\", \"usage\": {\"input_tokens\": 20, \"output_tokens\": 30, \"total_tokens\": 50}}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev7)

  let assert Some(types.StreamFinished(outcome, _)) = openai.terminal(reducer)
  case outcome {
    types.CompletedToolCalls(_text, calls, response_id) -> {
      response_id |> should.equal(Some("resp_1"))
      calls
      |> should.equal([
        types.ToolCall(
          id: expected_call_id1,
          name: expected_tool_name,
          arguments_json: "{\"city\": \"Tokyo\"}",
          provider_id: Some("call_weather_1"),
        ),
        types.ToolCall(
          id: expected_call_id2,
          name: expected_tool_name,
          arguments_json: "{\"city\": \"Paris\"}",
          provider_id: Some("call_weather_2"),
        ),
      ])
    }
    _ -> panic as "expected CompletedToolCalls"
  }
}

pub fn openai_provider_cancellation_is_not_attributed_to_local_owner_test() {
  let reducer = openai.new(types.default_limits())
  let completed =
    sse.ServerSentEvent(
      event: Some("response.completed"),
      data: "{\"response\":{\"id\":\"resp_cancelled\",\"status\":\"cancelled\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, completed)
  case openai.terminal(reducer) {
    Some(types.StreamFailed(types.ProviderError(Some("cancelled"), _), _)) ->
      should.be_true(True)
    _ -> should.fail()
  }
}

pub fn openai_invalid_json_arguments_test() {
  let tool = tool_fixtures.int_field_tool("calc", "x")
  let assert Ok(reducer) = openai.new_with_tools(types.default_limits(), [tool])
  let ev1 =
    sse.ServerSentEvent(
      event: Some("response.output_item.added"),
      data: "{\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"function_call\", \"call_id\": \"call_1\", \"name\": \"calc\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev1)

  let ev2 =
    sse.ServerSentEvent(
      event: Some("response.function_call_arguments.delta"),
      data: "{\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"{not valid json\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev2)

  let ev3 =
    sse.ServerSentEvent(
      event: Some("response.output_item.done"),
      data: "{\"output_index\": 0, \"item\": {\"id\": \"item_1\"}}",
      id: None,
      retry: None,
    )
  openai.step(reducer, ev3)
  |> should.be_error
}

pub fn openai_provider_error_test() {
  let reducer = openai.new(types.default_limits())
  let ev =
    sse.ServerSentEvent(
      event: Some("error"),
      data: "{\"error\": {\"code\": \"rate_limit\", \"message\": \"Too many requests\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev)
  openai.terminal(reducer)
  |> should.equal(
    Some(types.StreamFailed(
      error: types.ProviderError(
        code: Some("rate_limit"),
        message: "Too many requests",
      ),
      retry: types.RetryEvidence(
        classification: types.RequestMayHaveReachedProvider,
        response_bytes_observed: True,
        semantic_progress_observed: False,
      ),
    )),
  )
}

pub fn openai_future_extension_test() {
  let reducer = openai.new(types.default_limits())
  let ev =
    sse.ServerSentEvent(
      event: Some("response.some_new_feature"),
      data: "{\"info\": 123}",
      id: None,
      retry: None,
    )
  let assert Ok(#(_reducer, progress)) = openai.step(reducer, ev)
  progress
  |> should.equal([
    types.ProviderExtension(
      provider: "openai",
      event_name: "response.some_new_feature",
    ),
  ])
}
