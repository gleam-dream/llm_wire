import gleam/json
import gleam/option.{None, Some}
import gleeunit/should
import llm_wire/config
import llm_wire/internal/anthropic
import llm_wire/internal/openai
import llm_wire/internal/owner
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/provider/openai as openai_provider
import llm_wire/session
import llm_wire/testing
import llm_wire/types
import owner_provider_helper
import tool_fixtures

// Finding 6A: OpenAI duplicate output_index in output_item.added must be rejected
pub fn finding_6a_openai_duplicate_output_index_test() {
  let reducer = openai.new(types.default_limits())

  let ev1 =
    sse.ServerSentEvent(
      event: Some("response.output_item.added"),
      data: "{\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\", \"role\": \"assistant\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev1)

  // Second item with duplicate output_index 0 but different item_id
  let ev2 =
    sse.ServerSentEvent(
      event: Some("response.output_item.added"),
      data: "{\"output_index\": 0, \"item\": {\"id\": \"item_2\", \"type\": \"message\", \"role\": \"assistant\"}}",
      id: None,
      retry: None,
    )
  // Must fail with ProtocolError, not overwrite index_to_item_id
  case openai.step(reducer, ev2) {
    Error(types.ProtocolError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

// Finding 6B: OpenAI contradictory output_index and item_id must be rejected
pub fn finding_6b_openai_contradictory_routing_test() {
  let reducer = openai.new(types.default_limits())

  let ev1 =
    sse.ServerSentEvent(
      event: Some("response.output_item.added"),
      data: "{\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\", \"role\": \"assistant\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev1)

  let ev2 =
    sse.ServerSentEvent(
      event: Some("response.output_item.added"),
      data: "{\"output_index\": 1, \"item\": {\"id\": \"item_2\", \"type\": \"message\", \"role\": \"assistant\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev2)

  // Delta specifies output_index 0 (item_1) but item_id "item_2"
  let ev3 =
    sse.ServerSentEvent(
      event: Some("response.output_text.delta"),
      data: "{\"output_index\": 0, \"item_id\": \"item_2\", \"delta\": \"mismatch\"}",
      id: None,
      retry: None,
    )
  case openai.step(reducer, ev3) {
    Error(types.ProtocolError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

// Finding 6C: OpenAI incomplete text block at response.completed must be rejected
pub fn finding_6c_openai_incomplete_text_block_test() {
  let reducer = openai.new(types.default_limits())

  let ev1 =
    sse.ServerSentEvent(
      event: Some("response.output_item.added"),
      data: "{\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\", \"role\": \"assistant\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev1)

  let ev2 =
    sse.ServerSentEvent(
      event: Some("response.output_text.delta"),
      data: "{\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"unfinished...\"}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = openai.step(reducer, ev2)

  // response.completed arriving without response.output_item.done for item_1
  let ev3 =
    sse.ServerSentEvent(
      event: Some("response.completed"),
      data: "{\"response\": {\"id\": \"resp_1\", \"status\": \"completed\"}}",
      id: None,
      retry: None,
    )
  case openai.step(reducer, ev3) {
    Error(types.ProtocolError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

// Finding 6D: Anthropic delta.type mismatch with block type must be rejected
pub fn finding_6d_anthropic_delta_type_mismatch_test() {
  let reducer = anthropic.new(types.default_limits())

  let ev1 =
    sse.ServerSentEvent(
      event: Some("message_start"),
      data: "{\"type\": \"message_start\", \"message\": {\"id\": \"msg_1\", \"type\": \"message\", \"role\": \"assistant\", \"model\": \"claude-3-5\", \"usage\": {\"input_tokens\": 15, \"output_tokens\": 1}}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev1)

  // Start a text block
  let ev2 =
    sse.ServerSentEvent(
      event: Some("content_block_start"),
      data: "{\"type\": \"content_block_start\", \"index\": 0, \"content_block\": {\"type\": \"text\", \"text\": \"\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, ev2)

  // Send input_json_delta to text block!
  let ev3 =
    sse.ServerSentEvent(
      event: Some("content_block_delta"),
      data: "{\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"input_json_delta\", \"partial_json\": \"{}\"}}",
      id: None,
      retry: None,
    )
  case anthropic.step(reducer, ev3) {
    Error(types.ProtocolError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn finding_8_anthropic_hosted_effect_is_unknown_after_failure_test() {
  let reducer = anthropic.new(types.default_limits())
  let start =
    sse.ServerSentEvent(
      event: Some("content_block_start"),
      data: "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"server_tool_use\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, start)
  let failure =
    sse.ServerSentEvent(
      event: Some("error"),
      data: "{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"failure\"}}",
      id: None,
      retry: None,
    )
  let assert Ok(#(reducer, _)) = anthropic.step(reducer, failure)
  case anthropic.terminal(reducer) {
    Some(stream_types.StreamFailed(_, evidence)) ->
      evidence.classification |> should.equal(types.EffectUnknown)
    _ -> should.fail()
  }
}

// Finding 5A: Owner timed-out read must not cause ConcurrentReadConflict on next read
pub fn finding_5a_owner_timeout_read_cleanup_test() {
  let dummy_transport =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      types.default_limits(),
      types.default_deadlines(),
      dummy_transport,
    )

  // Call next with 10ms timeout when no data has been fed
  let res1 = owner.next(stream, 10)
  res1 |> should.equal(Error(types.ReadTimeout))

  // The caller calls next again. It should NOT return ConcurrentReadConflict
  let res2 = owner.next(stream, 10)
  res2 |> should.not_equal(Error(types.ConcurrentReadConflict))

  let _ = owner.close(stream)
  Nil
}

// Finding 7: Provider terminal must take precedence over late progress queue failure
pub fn terminal_cannot_bypass_queue_admission_failure_test() {
  let limits =
    types.Limits(
      ..types.default_limits(),
      queue_count_limit: 1,
      queue_bytes_limit: 100_000,
    )
  let dummy_transport =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      limits,
      types.default_deadlines(),
      dummy_transport,
    )

  // Add an item and text delta to fill the queue with 1 item
  owner.feed_chunk(stream, <<
    "event: response.output_item.added\ndata: {\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\", \"role\": \"assistant\"}}\n\n":utf8,
  >>)
  owner.feed_chunk(stream, <<
    "event: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"Hi\"}\n\n":utf8,
  >>)
  owner.feed_chunk(stream, <<
    "event: response.output_item.done\ndata: {\"output_index\": 0, \"item_id\": \"item_1\"}\n\n":utf8,
  >>)

  // Queue now has 1 TextDelta item. Now feed response.completed with usage!
  // This produces UsageUpdate (which exceeds queue_count_limit of 1) and a
  // nominal completed terminal. The admission failure remains authoritative.
  owner.feed_chunk(stream, <<
    "event: response.completed\ndata: {\"response\": {\"id\": \"resp_1\", \"status\": \"completed\", \"usage\": {\"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2}}}\n\n":utf8,
  >>)

  // Read until terminal:
  let assert Ok(stream_types.NextProgress(_)) = owner.next(stream, 1000)
  let term_res = owner.next(stream, 1000)
  case term_res {
    Ok(stream_types.StreamTerminal(stream_types.StreamFailed(
      types.ResourceLimitExceeded("queue_count_limit", _, _),
      _,
    ))) -> should.be_true(True)
    _ -> should.fail()
  }

  let _ = owner.close(stream)
  Nil
}

// Finding 1: completed calls are admitted by the runtime before any pending
// turn is returned; the reducer only decodes them.
pub fn finding_1_unadmitted_tool_is_rejected_before_a_pending_turn_test() {
  assert_openai_call_rejected("unknown", "{\"city\":\"Oslo\"}")
}

pub fn finding_1_invalid_native_schema_arguments_are_not_emitted_test() {
  assert_openai_call_rejected("weather", "{\"city\":42}")
}

fn assert_openai_call_rejected(name: String, arguments: String) -> Nil {
  let assert Ok(key) = types.api_key("sk-scripted")
  let assert Ok(model) = types.model_id("regression-model")
  let body =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\""
    <> name
    <> "\"}}\n\n"
    <> "event: response.function_call_arguments.delta\ndata: {\"output_index\":0,\"item_id\":\"item_1\",\"delta\":"
    <> json.to_string(json.string(arguments))
    <> "}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}\n\n"
  let script = testing.start([testing.Events([body])])
  let settings =
    config.openai(openai_provider.options(key)) |> testing.with_script(script)
  let request =
    types.new_request(model, [types.UserMessage("Weather?")])
    |> types.with_tools([tool_fixtures.string_field_tool("weather", "city")])
  let assert Ok(prepared) = session.prepare(settings, request)
  case session.run(prepared) {
    Error(session.RunFailure(types.ProtocolError(_), _)) -> Nil
    _ -> should.fail()
  }
}

pub fn finding_1_duplicate_catalog_names_are_rejected_test() {
  let first = tool_fixtures.string_field_tool("weather", "city")
  let second = tool_fixtures.string_field_tool("weather", "location")

  case openai.new_with_tools(types.default_limits(), [first, second]) {
    Error(types.PreparationError(_)) -> should.be_true(True)
    _ -> should.fail()
  }
}
