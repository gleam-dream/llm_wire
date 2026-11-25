import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import llm_wire/error
import llm_wire/internal/limits
import llm_wire/internal/openai
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/message

fn event(name: String, data: String) -> sse.ServerSentEvent {
  sse.ServerSentEvent(event: Some(name), data: data, id: None, retry: None)
}

pub fn openai_refusal_delta_is_reduced_and_terminally_refused_test() {
  let reducer = openai.new(limits.default())
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
    message.RefusalDelta(block_id: "msg_1", text: "I cannot help with that."),
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
    Some(stream_types.StreamFinished(
      outcome: stream_types.Refused("I cannot help with that."),
      usage: None,
    )),
  )
}

pub fn openai_reasoning_summary_delta_is_routed_and_completed_test() {
  let reducer = openai.new(limits.default())
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
    message.ReasoningDelta(block_id: "reason_1", text: "Checking the result."),
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
    Some(stream_types.StreamFinished(
      outcome: stream_types.CompletedText(""),
      usage: None,
    )),
  )
}

pub fn openai_incomplete_reasoning_item_cannot_complete_response_test() {
  let reducer = openai.new(limits.default())
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
  let reducer = openai.new(limits.default())
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
  let reducer = openai.new(limits.default())
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
  let reducer = openai.new(limits.default())

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
  |> should.equal([message.TextDelta(block_id: "item_1", text: "Hello ")])

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
  |> should.equal([message.TextDelta(block_id: "item_1", text: "world!")])

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
    message.UsageUpdate(message.Usage(
      input_tokens: 10,
      output_tokens: 5,
      total_tokens: 15,
      thought_tokens: None,
    )),
  ])

  openai.terminal(reducer)
  |> should.equal(
    Some(stream_types.StreamFinished(
      outcome: stream_types.CompletedText("Hello world!"),
      usage: Some(message.Usage(
        input_tokens: 10,
        output_tokens: 5,
        total_tokens: 15,
        thought_tokens: None,
      )),
    )),
  )
}

pub fn openai_interleaved_tool_calls_test() {
  // The runtime admits calls against declared tools at the terminal.
  let reducer = openai.new(limits.default())

  // Add tool call 1: item_1, index 0, call_id "call_weather_1"
  let ev1 =
    sse.ServerSentEvent(
      event: Some("response.output_item.added"),
      data: "{\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"function_call\", \"call_id\": \"call_weather_1\", \"name\": \"get_weather\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev1)

  // Two calls to the same tool have distinct routing and application ids.
  let ev2 =
    sse.ServerSentEvent(
      event: Some("response.output_item.added"),
      data: "{\"output_index\": 1, \"item\": {\"id\": \"item_2\", \"type\": \"function_call\", \"call_id\": \"call_weather_2\", \"name\": \"get_weather\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev2)

  // Call 2 receives arguments first; terminal calls must retain start order.
  let ev3 =
    sse.ServerSentEvent(
      event: Some("response.function_call_arguments.delta"),
      data: "{\"output_index\": 1, \"item_id\": \"item_2\", \"delta\": \"{\\\"city\\\": \\\"Paris\\\"}\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p3)) = openai.step(reducer, ev3)
  // Argument progress uses the application call id, not the item routing id.
  p3
  |> should.equal([
    message.ToolArgumentsDelta("call_weather_2", "{\"city\": \"Paris\"}"),
  ])

  // Then chunk for call 1
  let ev4 =
    sse.ServerSentEvent(
      event: Some("response.function_call_arguments.delta"),
      data: "{\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"{\\\"city\\\": \\\"Tokyo\\\"}\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p4)) = openai.step(reducer, ev4)
  p4
  |> should.equal([
    message.ToolArgumentsDelta("call_weather_1", "{\"city\": \"Tokyo\"}"),
  ])

  // Done for call 1
  let ev5 =
    sse.ServerSentEvent(
      event: Some("response.output_item.done"),
      data: "{\"output_index\": 0, \"item\": {\"id\": \"item_1\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p5)) = openai.step(reducer, ev5)
  let expected_call_id1 = "call_weather_1"
  let expected_tool_name = "get_weather"
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
  let expected_call_id2 = "call_weather_2"
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

  let assert Some(stream_types.StreamFinished(outcome, _)) =
    openai.terminal(reducer)
  case outcome {
    stream_types.CompletedToolCalls(_text, calls, response_id, []) -> {
      response_id |> should.equal(Some("resp_1"))
      calls
      |> should.equal([
        message.ToolCall(
          id: expected_call_id1,
          name: expected_tool_name,
          arguments_json: "{\"city\": \"Tokyo\"}",
          provider_id: Some("call_weather_1"),
          provider_state: None,
        ),
        message.ToolCall(
          id: expected_call_id2,
          name: expected_tool_name,
          arguments_json: "{\"city\": \"Paris\"}",
          provider_id: Some("call_weather_2"),
          provider_state: None,
        ),
      ])
    }
    _ -> panic as "expected CompletedToolCalls"
  }
}

pub fn openai_provider_cancellation_is_not_attributed_to_local_owner_test() {
  let reducer = openai.new(limits.default())
  let completed =
    sse.ServerSentEvent(
      event: Some("response.completed"),
      data: "{\"response\":{\"id\":\"resp_cancelled\",\"status\":\"cancelled\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, completed)
  case openai.terminal(reducer) {
    Some(stream_types.StreamFailed(error.Provider(Some("cancelled"), _), _)) ->
      should.be_true(True)
    _ -> should.fail()
  }
}

pub fn openai_provider_error_test() {
  let reducer = openai.new(limits.default())
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
    Some(stream_types.StreamFailed(
      error: error.Provider(
        code: Some("rate_limit"),
        message: "Too many requests",
      ),
      retry: stream_types.RetryEvidence(
        classification: stream_types.RequestMayHaveReachedProvider,
        response_bytes_observed: True,
        semantic_progress_observed: False,
      ),
    )),
  )
}

pub fn openai_future_extension_test() {
  let reducer = openai.new(limits.default())
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
    message.UnrecognizedEvent(
      provider: "openai",
      name: "response.some_new_feature",
    ),
  ])
}

/// OpenAI's own order for one call: the item, its argument deltas, then
/// `response.function_call_arguments.done` with the whole arguments and
/// `response.output_item.done` with the whole item. Both done events close
/// the same call, and neither is a second completion.
fn real_tool_call_events(
  deltas: List(String),
  arguments_done: String,
) -> List(sse.ServerSentEvent) {
  [
    event(
      "response.output_item.added",
      "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"id\":\"fc_1\",\"type\":\"function_call\",\"status\":\"in_progress\",\"arguments\":\"\",\"call_id\":\"call_1\",\"name\":\"get_weather\"}}",
    ),
    ..list.append(
      list.map(deltas, fn(delta) {
        event(
          "response.function_call_arguments.delta",
          "{\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"output_index\":1,\"delta\":"
            <> json.to_string(json.string(delta))
            <> "}",
        )
      }),
      [
        event(
          "response.function_call_arguments.done",
          "{\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_1\",\"output_index\":1,\"arguments\":"
            <> json.to_string(json.string(arguments_done))
            <> "}",
        ),
        event(
          "response.output_item.done",
          "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"id\":\"fc_1\",\"type\":\"function_call\",\"status\":\"completed\",\"arguments\":"
            <> json.to_string(json.string(arguments_done))
            <> ",\"call_id\":\"call_1\",\"name\":\"get_weather\"}}",
        ),
        event(
          "response.completed",
          "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":20,\"output_tokens\":30,\"total_tokens\":50}}}",
        ),
      ],
    )
  ]
}

fn run_events(
  events: List(sse.ServerSentEvent),
) -> Result(openai.Reducer, error.Error) {
  // The reasoning item OpenAI streams before the call, at index 0.
  let reasoning = [
    event(
      "response.output_item.added",
      "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[]}}",
    ),
    event(
      "response.output_item.done",
      "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"id\":\"rs_1\",\"type\":\"reasoning\",\"summary\":[]}}",
    ),
  ]
  list.try_fold(
    list.append(reasoning, events),
    openai.new(limits.default()),
    fn(reducer, next) {
      openai.step(reducer, next) |> result.map(fn(stepped) { stepped.0 })
    },
  )
}

fn completed_calls(reducer: openai.Reducer) -> List(message.ToolCall) {
  let assert Some(stream_types.StreamFinished(
    stream_types.CompletedToolCalls(_, calls, _, []),
    _,
  )) = openai.terminal(reducer)
  calls
}

pub fn openai_arguments_done_and_item_done_complete_one_call_test() {
  let assert Ok(reducer) =
    run_events(real_tool_call_events(
      ["{\"city\":", "\"Paris\"}"],
      "{\"city\":\"Paris\"}",
    ))
  let assert [call] = completed_calls(reducer)
  call.id |> should.equal("call_1")
  call.arguments_json |> should.equal("{\"city\":\"Paris\"}")
}

pub fn openai_arguments_done_without_deltas_supplies_the_arguments_test() {
  let assert Ok(reducer) =
    run_events(real_tool_call_events([], "{\"city\":\"Paris\"}"))
  let assert [call] = completed_calls(reducer)
  call.arguments_json |> should.equal("{\"city\":\"Paris\"}")
}

pub fn openai_arguments_done_that_contradicts_the_deltas_fails_test() {
  let assert Error(error.Protocol(detail)) =
    run_events(real_tool_call_events(
      ["{\"city\":\"Paris\"}"],
      "{\"city\":\"Rome\"}",
    ))
  string.contains(detail, "arguments") |> should.be_true
}

pub fn openai_a_second_item_done_is_still_a_duplicate_test() {
  let events = real_tool_call_events(["{}"], "{}")
  let assert [added, delta, arguments_done, item_done, completed] = events
  let assert Error(error.Protocol("Duplicate tool block completion")) =
    run_events([added, delta, arguments_done, item_done, item_done, completed])
}
