import gleam/json
import gleam/option.{None, Some}
import gleeunit/should
import http_test_helpers
import llm_wire
import llm_wire/error
import llm_wire/internal/anthropic
import llm_wire/internal/config
import llm_wire/internal/limits
import llm_wire/internal/openai
import llm_wire/internal/owner
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/limit
import llm_wire/openai as openai_provider
import llm_wire/testing
import owner_provider_helper
import tool_fixtures

fn event(name: String, data: String) -> sse.ServerSentEvent {
  sse.ServerSentEvent(event: Some(name), data:, id: None, retry: None)
}

fn is_protocol(result: Result(a, error.Error)) -> Bool {
  case result {
    Error(error.Protocol(_)) -> True
    _ -> False
  }
}

// Finding 6A: OpenAI duplicate output_index in output_item.added must be rejected
pub fn finding_6a_openai_duplicate_output_index_test() {
  let reducer = openai.new(limits.default())
  let assert Ok(#(reducer, _)) =
    openai.step(
      reducer,
      event(
        "response.output_item.added",
        "{\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\", \"role\": \"assistant\"}}",
      ),
    )
  // Second item with duplicate output_index 0 but different item_id must fail
  // with a protocol error, not overwrite the index routing.
  openai.step(
    reducer,
    event(
      "response.output_item.added",
      "{\"output_index\": 0, \"item\": {\"id\": \"item_2\", \"type\": \"message\", \"role\": \"assistant\"}}",
    ),
  )
  |> is_protocol
  |> should.be_true
}

// Finding 6B: OpenAI contradictory output_index and item_id must be rejected
pub fn finding_6b_openai_contradictory_routing_test() {
  let reducer = openai.new(limits.default())
  let assert Ok(#(reducer, _)) =
    openai.step(
      reducer,
      event(
        "response.output_item.added",
        "{\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\", \"role\": \"assistant\"}}",
      ),
    )
  let assert Ok(#(reducer, _)) =
    openai.step(
      reducer,
      event(
        "response.output_item.added",
        "{\"output_index\": 1, \"item\": {\"id\": \"item_2\", \"type\": \"message\", \"role\": \"assistant\"}}",
      ),
    )
  // Delta specifies output_index 0 (item_1) but item_id "item_2"
  openai.step(
    reducer,
    event(
      "response.output_text.delta",
      "{\"output_index\": 0, \"item_id\": \"item_2\", \"delta\": \"mismatch\"}",
    ),
  )
  |> is_protocol
  |> should.be_true
}

// Finding 6C: OpenAI incomplete text block at response.completed must be rejected
pub fn finding_6c_openai_incomplete_text_block_test() {
  let reducer = openai.new(limits.default())
  let assert Ok(#(reducer, _)) =
    openai.step(
      reducer,
      event(
        "response.output_item.added",
        "{\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\", \"role\": \"assistant\"}}",
      ),
    )
  let assert Ok(#(reducer, _)) =
    openai.step(
      reducer,
      event(
        "response.output_text.delta",
        "{\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"unfinished...\"}",
      ),
    )
  // response.completed arriving without response.output_item.done for item_1
  openai.step(
    reducer,
    event(
      "response.completed",
      "{\"response\": {\"id\": \"resp_1\", \"status\": \"completed\"}}",
    ),
  )
  |> is_protocol
  |> should.be_true
}

// Finding 6D: Anthropic delta.type mismatch with block type must be rejected
pub fn finding_6d_anthropic_delta_type_mismatch_test() {
  let reducer = anthropic.new(limits.default())
  let assert Ok(#(reducer, _)) =
    anthropic.step(
      reducer,
      event(
        "message_start",
        "{\"type\": \"message_start\", \"message\": {\"id\": \"msg_1\", \"type\": \"message\", \"role\": \"assistant\", \"model\": \"claude-3-5\", \"usage\": {\"input_tokens\": 15, \"output_tokens\": 1}}}",
      ),
    )
  let assert Ok(#(reducer, _)) =
    anthropic.step(
      reducer,
      event(
        "content_block_start",
        "{\"type\": \"content_block_start\", \"index\": 0, \"content_block\": {\"type\": \"text\", \"text\": \"\"}}",
      ),
    )
  // An input_json_delta sent to a text block.
  anthropic.step(
    reducer,
    event(
      "content_block_delta",
      "{\"type\": \"content_block_delta\", \"index\": 0, \"delta\": {\"type\": \"input_json_delta\", \"partial_json\": \"{}\"}}",
    ),
  )
  |> is_protocol
  |> should.be_true
}

pub fn finding_8_anthropic_hosted_effect_is_unknown_after_failure_test() {
  let reducer = anthropic.new(limits.default())
  let assert Ok(#(reducer, _)) =
    anthropic.step(
      reducer,
      event(
        "content_block_start",
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"server_tool_use\"}}",
      ),
    )
  let assert Ok(#(reducer, _)) =
    anthropic.step(
      reducer,
      event(
        "error",
        "{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"failure\"}}",
      ),
    )
  let assert Some(stream_types.StreamFailed(_, evidence)) =
    anthropic.terminal(reducer)
  evidence.classification |> should.equal(stream_types.EffectUnknown)
}

fn idle_transport() -> owner.TransportPort {
  owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })
}

// Finding 5A: Owner timed-out read must not cause ConcurrentReadConflict on next read
pub fn finding_5a_owner_timeout_read_cleanup_test() {
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      limits.default(),
      config.default_timeouts(),
      idle_transport(),
    )
  // A 10 ms read with no data fed times out.
  owner.next(stream, Some(10)) |> should.equal(Error(stream_types.ReadTimeout))
  // The next read must not see the abandoned one as concurrent.
  owner.next(stream, Some(10))
  |> should.not_equal(Error(stream_types.ConcurrentReadConflict))
  let _ = owner.close(stream)
  Nil
}

// Finding 7: Provider terminal must take precedence over late progress queue failure
pub fn terminal_cannot_bypass_queue_admission_failure_test() {
  let bounds =
    limits.default()
    |> limits.set(limit.QueueCount, 1)
    |> limits.set(limit.QueueBytes, 100_000)
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      bounds,
      config.default_timeouts(),
      idle_transport(),
    )
  owner.feed_chunk(stream, <<
    "event: response.output_item.added\ndata: {\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\", \"role\": \"assistant\"}}\n\n":utf8,
  >>)
  owner.feed_chunk(stream, <<
    "event: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"Hi\"}\n\n":utf8,
  >>)
  owner.feed_chunk(stream, <<
    "event: response.output_item.done\ndata: {\"output_index\": 0, \"item_id\": \"item_1\"}\n\n":utf8,
  >>)
  // The queue holds one TextDelta. response.completed with usage produces a
  // UsageUpdate beyond the queue count limit and a nominal completed
  // terminal; the admission failure remains authoritative.
  owner.feed_chunk(stream, <<
    "event: response.completed\ndata: {\"response\": {\"id\": \"resp_1\", \"status\": \"completed\", \"usage\": {\"input_tokens\": 1, \"output_tokens\": 1, \"total_tokens\": 2}}}\n\n":utf8,
  >>)
  let assert Ok(stream_types.NextProgress(_)) = owner.next(stream, Some(1000))
  let assert Ok(stream_types.StreamTerminal(
    stream_types.StreamFailed(error.LimitExceeded(limit.QueueCount, _, _), _),
    _,
  )) = owner.next(stream, Some(1000))
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
  let body =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\",\"type\":\"function_call\",\"call_id\":\"call_1\",\"name\":\""
    <> name
    <> "\"}}\n\n"
    <> "event: response.function_call_arguments.delta\ndata: {\"output_index\":0,\"item_id\":\"item_1\",\"delta\":"
    <> json.to_string(json.string(arguments))
    <> "}\n\n"
    <> "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\"}}\n\n"
    <> "event: response.completed\ndata: {\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}\n\n"
  let request =
    llm_wire.request("regression-model", [llm_wire.user("Weather?")])
    |> llm_wire.with_tools([tool_fixtures.string_field_tool("weather", "city")])
  let assert Ok(prepared) =
    llm_wire.prepare(
      openai_provider.new("sk-scripted") |> openai_provider.config,
      request,
    )
  let assert Error(llm_wire.Failure(error: error.Protocol(_), ..)) =
    http_test_helpers.run_reply(prepared, testing.events([body]))
  Nil
}

// `new_with_tools` is gone: duplicate declarations are refused by `prepare`.
pub fn finding_1_duplicate_catalog_names_are_rejected_test() {
  let first = tool_fixtures.string_field_tool("weather", "city")
  let second = tool_fixtures.string_field_tool("weather", "location")
  let request =
    llm_wire.request("regression-model", [llm_wire.user("Weather?")])
    |> llm_wire.with_tools([first, second])
  llm_wire.prepare(
    openai_provider.new("sk-scripted") |> openai_provider.config,
    request,
  )
  |> should.equal(
    Error(error.InvalidRequest(error.DuplicateToolName("weather"))),
  )
}
