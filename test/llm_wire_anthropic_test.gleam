import gleam/option.{None, Some}
import gleeunit/should
import llm_wire/internal/anthropic
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/types
import tool_fixtures

pub fn anthropic_text_stream_test() {
  let reducer = anthropic.new(types.default_limits())

  // message_start
  let ev1 =
    sse.ServerSentEvent(
      event: Some("message_start"),
      data: "{\"type\": \"message_start\", \"message\": {\"id\": \"msg_1\", \"type\": \"message\", \"role\": \"assistant\", \"model\": \"claude-3-5\", \"usage\": {\"input_tokens\": 15, \"output_tokens\": 1}}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p1)) = anthropic.step(reducer, ev1)
  p1 |> should.equal([])

  // content_block_start (text, index 0)
  let ev2 =
    sse.ServerSentEvent(
      event: Some("content_block_start"),
      data: "{\"type\": \"content_block_start\", \"index\": 0, \"content_block\": {\"type\": \"text\", \"text\": \"\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p2)) = anthropic.step(reducer, ev2)
  p2 |> should.equal([])

  // content_block_delta (text)
  let ev3 =
    sse.ServerSentEvent(
      event: Some("content_block_delta"),
      data: "{\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"text_delta\", \"text\": \"Hello \"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p3)) = anthropic.step(reducer, ev3)
  p3
  |> should.equal([types.TextDelta(block_id: "0", text: "Hello ")])

  // ping event (should be ignored)
  let ev_ping =
    sse.ServerSentEvent(
      event: Some("ping"),
      data: "{\"type\": \"ping\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p_ping)) = anthropic.step(reducer, ev_ping)
  p_ping |> should.equal([])

  // content_block_delta (second text)
  let ev4 =
    sse.ServerSentEvent(
      event: Some("content_block_delta"),
      data: "{\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"text_delta\", \"text\": \"Claude!\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p4)) = anthropic.step(reducer, ev4)
  p4
  |> should.equal([types.TextDelta(block_id: "0", text: "Claude!")])

  // content_block_stop (index 0)
  let ev5 =
    sse.ServerSentEvent(
      event: Some("content_block_stop"),
      data: "{\"type\": \"content_block_stop\", \"index\": 0}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p5)) = anthropic.step(reducer, ev5)
  p5 |> should.equal([])

  // message_delta (cumulative usage + stop_reason)
  let ev6 =
    sse.ServerSentEvent(
      event: Some("message_delta"),
      data: "{\"type\": \"message_delta\", \"delta\": {\"stop_reason\": \"end_turn\"}, \"usage\": {\"output_tokens\": 10}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p6)) = anthropic.step(reducer, ev6)
  p6
  |> should.equal([
    types.UsageUpdate(types.Usage(
      input_tokens: 15,
      output_tokens: 10,
      total_tokens: 25,
    )),
  ])

  // message_stop
  let ev7 =
    sse.ServerSentEvent(
      event: Some("message_stop"),
      data: "{\"type\": \"message_stop\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p7)) = anthropic.step(reducer, ev7)
  p7 |> should.equal([])

  anthropic.terminal(reducer)
  |> should.equal(
    Some(stream_types.StreamFinished(
      outcome: stream_types.CompletedText("Hello Claude!"),
      usage: Some(types.Usage(
        input_tokens: 15,
        output_tokens: 10,
        total_tokens: 25,
      )),
    )),
  )
}

pub fn anthropic_tool_use_stream_test() {
  let tool = tool_fixtures.string_field_tool("get_stock_price", "symbol")
  let assert Ok(reducer) =
    anthropic.new_with_tools(types.default_limits(), [tool])

  // message_start
  let ev1 =
    sse.ServerSentEvent(
      event: Some("message_start"),
      data: "{\"type\": \"message_start\", \"message\": {\"id\": \"msg_2\", \"type\": \"message\", \"role\": \"assistant\", \"model\": \"claude-3-5\", \"usage\": {\"input_tokens\": 20, \"output_tokens\": 1}}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev1)

  // content_block_start index 0: tool_use
  let ev2 =
    sse.ServerSentEvent(
      event: Some("content_block_start"),
      data: "{\"type\": \"content_block_start\", \"index\": 0, \"content_block\": {\"type\": \"tool_use\", \"id\": \"toolu_123\", \"name\": \"get_stock_price\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev2)

  // content_block_delta index 0: input_json_delta fragment 1
  let ev3 =
    sse.ServerSentEvent(
      event: Some("content_block_delta"),
      data: "{\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"input_json_delta\", \"partial_json\": \"{\\\"symbol\\\": \"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p3)) = anthropic.step(reducer, ev3)
  p3 |> should.equal([])

  // content_block_delta index 0: input_json_delta fragment 2
  let ev4 =
    sse.ServerSentEvent(
      event: Some("content_block_delta"),
      data: "{\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"input_json_delta\", \"partial_json\": \"\\\"AAPL\\\"}\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p4)) = anthropic.step(reducer, ev4)
  p4 |> should.equal([])

  // Closing a block validates it but keeps executable calls private until terminal.
  let ev5 =
    sse.ServerSentEvent(
      event: Some("content_block_stop"),
      data: "{\"type\": \"content_block_stop\", \"index\": 0}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p5)) = anthropic.step(reducer, ev5)
  let assert Ok(expected_call_id) = types.call_id("toolu_123")
  let assert Ok(expected_tool_name) = types.tool_name("get_stock_price")
  p5 |> should.equal([])

  // message_delta
  let ev6 =
    sse.ServerSentEvent(
      event: Some("message_delta"),
      data: "{\"type\": \"message_delta\", \"delta\": {\"stop_reason\": \"tool_use\"}, \"usage\": {\"output_tokens\": 35}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev6)

  // message_stop
  let ev7 =
    sse.ServerSentEvent(
      event: Some("message_stop"),
      data: "{\"type\": \"message_stop\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev7)

  let assert Some(stream_types.StreamFinished(outcome, usage)) =
    anthropic.terminal(reducer)
  usage
  |> should.equal(
    Some(types.Usage(input_tokens: 20, output_tokens: 35, total_tokens: 55)),
  )

  case outcome {
    stream_types.CompletedToolCalls(_text, calls, response_id, []) -> {
      response_id |> should.equal(Some("msg_2"))
      calls
      |> should.equal([
        types.ToolCall(
          id: expected_call_id,
          name: expected_tool_name,
          arguments_json: "{\"symbol\": \"AAPL\"}",
          provider_id: Some("toolu_123"),
          provider_state: None,
        ),
      ])
    }
    _ -> panic as "expected CompletedToolCalls"
  }
}

pub fn anthropic_server_tool_test() {
  let reducer = anthropic.new(types.default_limits())
  let ev1 =
    sse.ServerSentEvent(
      event: Some("content_block_start"),
      data: "{\"type\": \"content_block_start\", \"index\": 0, \"content_block\": {\"type\": \"server_tool_use\", \"id\": \"srv_1\", \"name\": \"web_search\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev1)

  let ev2 =
    sse.ServerSentEvent(
      event: Some("content_block_delta"),
      data: "{\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"input_json_delta\", \"partial_json\": \"{\\\"query\\\": \\\"gleam\\\"}\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev2)

  let ev3 =
    sse.ServerSentEvent(
      event: Some("content_block_stop"),
      data: "{\"type\": \"content_block_stop\", \"index\": 0}",
      id: None,
      retry: None,
    )
  let assert Ok(#(_reducer, progress)) = anthropic.step(reducer, ev3)
  // Server tool MUST NOT be emitted as application tool call!
  progress |> should.equal([])
}

pub fn anthropic_incomplete_block_at_stop_test() {
  let reducer = anthropic.new(types.default_limits())
  let ev1 =
    sse.ServerSentEvent(
      event: Some("content_block_start"),
      data: "{\"type\": \"content_block_start\", \"index\": 0, \"content_block\": {\"type\": \"text\", \"text\": \"\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev1)

  // Send message_stop without closing block 0
  let ev2 =
    sse.ServerSentEvent(
      event: Some("message_stop"),
      data: "{\"type\": \"message_stop\"}",
      id: None,
      retry: None,
    )
  anthropic.step(reducer, ev2)
  |> should.be_error
}

pub fn anthropic_max_tokens_test() {
  let reducer = anthropic.new(types.default_limits())
  let ev1 =
    sse.ServerSentEvent(
      event: Some("content_block_start"),
      data: "{\"type\": \"content_block_start\", \"index\": 0, \"content_block\": {\"type\": \"text\", \"text\": \"\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev1)

  let ev2 =
    sse.ServerSentEvent(
      event: Some("content_block_delta"),
      data: "{\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"text_delta\", \"text\": \"Cut off...\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev2)

  let ev3 =
    sse.ServerSentEvent(
      event: Some("content_block_stop"),
      data: "{\"type\": \"content_block_stop\", \"index\": 0}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev3)

  let ev4 =
    sse.ServerSentEvent(
      event: Some("message_delta"),
      data: "{\"type\": \"message_delta\", \"delta\": {\"stop_reason\": \"max_tokens\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev4)

  let ev5 =
    sse.ServerSentEvent(
      event: Some("message_stop"),
      data: "{\"type\": \"message_stop\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev5)

  let assert Some(stream_types.StreamFinished(outcome, _)) =
    anthropic.terminal(reducer)
  outcome
  |> should.equal(
    stream_types.OutputLimited(partial_text: "Cut off...", partial_calls: []),
  )
}

pub fn anthropic_cumulative_usage_replacement_test() {
  let reducer = anthropic.new(types.default_limits())

  let ev1 =
    sse.ServerSentEvent(
      event: Some("message_start"),
      data: "{\"type\": \"message_start\", \"message\": {\"id\": \"msg_3\", \"usage\": {\"input_tokens\": 100, \"output_tokens\": 1}}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev1)

  // delta 1: output_tokens: 10
  let ev2 =
    sse.ServerSentEvent(
      event: Some("message_delta"),
      data: "{\"type\": \"message_delta\", \"delta\": {}, \"usage\": {\"output_tokens\": 10}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, p2)) = anthropic.step(reducer, ev2)
  p2
  |> should.equal([
    types.UsageUpdate(types.Usage(
      input_tokens: 100,
      output_tokens: 10,
      total_tokens: 110,
    )),
  ])

  // delta 2: output_tokens: 25 (cumulative snapshot replaces 10, NOT added!)
  let ev3 =
    sse.ServerSentEvent(
      event: Some("message_delta"),
      data: "{\"type\": \"message_delta\", \"delta\": {}, \"usage\": {\"output_tokens\": 25}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(_reducer, p3)) = anthropic.step(reducer, ev3)
  p3
  |> should.equal([
    types.UsageUpdate(types.Usage(
      input_tokens: 100,
      output_tokens: 25,
      total_tokens: 125,
    )),
  ])
}

pub fn anthropic_error_test() {
  let reducer = anthropic.new(types.default_limits())
  let ev =
    sse.ServerSentEvent(
      event: Some("error"),
      data: "{\"type\": \"error\", \"error\": {\"type\": \"overloaded_error\", \"message\": \"Service is temporarily overloaded\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev)
  anthropic.terminal(reducer)
  |> should.equal(
    Some(stream_types.StreamFailed(
      error: types.ProviderError(
        code: Some("overloaded_error"),
        message: "Service is temporarily overloaded",
      ),
      retry: types.RetryEvidence(
        classification: types.RequestMayHaveReachedProvider,
        response_bytes_observed: True,
        semantic_progress_observed: False,
      ),
    )),
  )
}

pub fn anthropic_refusal_terminal_is_a_refusal_result_test() {
  let reducer = anthropic.new(types.default_limits())
  let start =
    sse.ServerSentEvent(
      event: Some("content_block_start"),
      data: "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, start)
  let delta =
    sse.ServerSentEvent(
      event: Some("content_block_delta"),
      data: "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"I cannot help with that request.\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, delta)
  let stop_block =
    sse.ServerSentEvent(
      event: Some("content_block_stop"),
      data: "{\"type\":\"content_block_stop\",\"index\":0}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, stop_block)
  let stop_reason =
    sse.ServerSentEvent(
      event: Some("message_delta"),
      data: "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"refusal\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, stop_reason)
  let message_stop =
    sse.ServerSentEvent(
      event: Some("message_stop"),
      data: "{\"type\":\"message_stop\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, message_stop)
  anthropic.terminal(reducer)
  |> should.equal(
    Some(stream_types.StreamFinished(
      stream_types.Refused("I cannot help with that request."),
      None,
    )),
  )
}

pub fn anthropic_unknown_stop_reason_is_not_reported_as_success_test() {
  let reducer = anthropic.new(types.default_limits())
  let stop_reason =
    sse.ServerSentEvent(
      event: Some("message_delta"),
      data: "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"future_state\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, stop_reason)
  let message_stop =
    sse.ServerSentEvent(
      event: Some("message_stop"),
      data: "{\"type\":\"message_stop\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, message_stop)
  case anthropic.terminal(reducer) {
    Some(stream_types.StreamFailed(
      types.ProviderError(Some("future_state"), _),
      _,
    )) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn anthropic_successful_hosted_effect_remains_effect_unknown_test() {
  let reducer = anthropic.new(types.default_limits())
  let start =
    sse.ServerSentEvent(
      event: Some("content_block_start"),
      data: "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"server_tool_use\",\"id\":\"srv_1\",\"name\":\"web_search\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, start)
  let stop_block =
    sse.ServerSentEvent(
      event: Some("content_block_stop"),
      data: "{\"type\":\"content_block_stop\",\"index\":0}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, stop_block)
  let stop_reason =
    sse.ServerSentEvent(
      event: Some("message_delta"),
      data: "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"pause_turn\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, stop_reason)
  let message_stop =
    sse.ServerSentEvent(
      event: Some("message_stop"),
      data: "{\"type\":\"message_stop\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, message_stop)
  case anthropic.terminal(reducer) {
    Some(stream_types.StreamFailed(
      types.ProviderError(Some("pause_turn"), _),
      types.RetryEvidence(classification: types.EffectUnknown, ..),
    )) -> should.be_true(True)
    _ -> should.fail()
  }
}
