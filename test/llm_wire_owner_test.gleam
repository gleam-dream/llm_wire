import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import http_gun/error as http_error
import llm_wire/error
import llm_wire/internal/config
import llm_wire/internal/limits
import llm_wire/internal/owner
import llm_wire/internal/stream_types
import llm_wire/limit
import llm_wire/message
import owner_provider_helper
import tool_fixtures

fn idle_port() -> owner.TransportPort {
  owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })
}

fn item_added() -> BitArray {
  <<
    "event: response.output_item.added\ndata: {\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\"}}\n\n":utf8,
  >>
}

fn text_delta(text: String) -> BitArray {
  <<
    "event: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"":utf8,
    text:utf8,
    "\"}\n\n":utf8,
  >>
}

pub fn owner_sequential_read_test() {
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      limits.default(),
      config.default_timeouts(),
      idle_port(),
    )

  owner.feed_chunk(stream, item_added())
  owner.feed_chunk(stream, text_delta("Hi!"))

  let assert Ok(stream_types.NextProgress(message.TextDelta(block_id, text))) =
    owner.next(stream, Some(1000))
  block_id |> should.equal("item_1")
  text |> should.equal("Hi!")

  owner.feed_chunk(stream, <<
    "event: response.output_item.done\ndata: {\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\"}}\n\n":utf8,
  >>)
  owner.feed_chunk(stream, <<
    "event: response.completed\ndata: {\"response\": {\"id\": \"r1\", \"status\": \"completed\"}}\n\n":utf8,
  >>)

  let assert Ok(stream_types.StreamTerminal(
    stream_types.StreamFinished(outcome, _),
    _,
  )) = owner.next(stream, Some(1000))
  outcome |> should.equal(stream_types.CompletedText("Hi!"))

  owner.next(stream, Some(1000))
  |> should.equal(Error(stream_types.StreamClosed))
}

pub fn owner_copied_handles_and_close_test() {
  let assert Ok(stream1) =
    owner_provider_helper.start_openai_stream(
      limits.default(),
      config.default_timeouts(),
      idle_port(),
    )
  let stream2 = stream1

  // `close` no longer returns a `Result`: it is always answered.
  owner.close(stream1) |> should.equal(stream_types.ConsumerClosed)
  owner.close(stream2) |> should.equal(stream_types.AlreadyTerminal)
  owner.next(stream2, Some(1000))
  |> should.equal(Error(stream_types.StreamClosed))
}

pub fn copied_handles_close_concurrently_and_idempotently_test() {
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      limits.default(),
      config.default_timeouts(),
      idle_port(),
    )
  let ready = process.new_subject()
  let done = process.new_subject()
  list.each(list.repeat(Nil, 50), fn(_) {
    let _ =
      process.spawn(fn() {
        let go = process.new_subject()
        process.send(ready, go)
        let assert Ok(Nil) = process.receive(go, 1000)
        process.send(done, owner.close(stream))
      })
    Nil
  })
  let gates =
    list.map(list.repeat(Nil, 50), fn(_) {
      let assert Ok(go) = process.receive(ready, 1000)
      go
    })
  list.each(gates, fn(go) { process.send(go, Nil) })
  let outcomes =
    list.map(gates, fn(_) {
      let assert Ok(outcome) = process.receive(done, 6000)
      outcome
    })
  // Exactly one close wins; every other copy sees the call already ended.
  list.count(outcomes, fn(o) { o == stream_types.ConsumerClosed })
  |> should.equal(1)
}

pub fn owner_concurrent_read_conflict_test() {
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      limits.default(),
      config.default_timeouts(),
      idle_port(),
    )

  let test_subject = process.new_subject()
  let registered = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(registered, Nil)
    process.send(test_subject, read_past_conflicts(stream))
  })
  let assert Ok(Nil) = process.receive(registered, 1000)
  // Poll until the background read waits with the owner; a concurrent read
  // from this process then fails at once.
  wait_for_conflict(stream, 200) |> should.be_true

  owner.close(stream) |> should.equal(stream_types.ConsumerClosed)
  // The waiting reader is released with the cancellation terminal.
  let assert Ok(Ok(stream_types.StreamTerminal(
    stream_types.StreamCancelledLocally(_),
    _,
  ))) = process.receive(test_subject, 2000)
}

/// A waiting read; a conflict with one of the test's polls is retried.
fn read_past_conflicts(
  stream: owner.Stream,
) -> Result(stream_types.ReadResult, stream_types.ReadError) {
  case owner.next(stream, None) {
    Error(stream_types.ConcurrentReadConflict) -> read_past_conflicts(stream)
    other -> other
  }
}

fn wait_for_conflict(stream: owner.Stream, attempts: Int) -> Bool {
  case owner.next(stream, Some(10)) {
    Error(stream_types.ConcurrentReadConflict) -> True
    _ if attempts > 0 -> {
      process.sleep(5)
      wait_for_conflict(stream, attempts - 1)
    }
    _ -> False
  }
}

/// The old idle deadline ran from the start; that span is now the
/// first-token timer, which fires when no progress arrives at all.
pub fn owner_first_token_deadline_test() {
  let timeouts = owner_provider_helper.timeouts(Some(10_000), Some(50), None)
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      limits.default(),
      timeouts,
      idle_port(),
    )
  // `next` waits; the owner's timer ends the wait.
  let assert Ok(stream_types.StreamTerminal(
    stream_types.StreamFailed(error.DeadlineExceeded(error.FirstToken), _),
    _,
  )) = owner.next(stream, None)
}

/// The idle gap starts at the first progress event, so it fires only after
/// a delta was delivered.
pub fn owner_idle_gap_deadline_test() {
  let timeouts = owner_provider_helper.timeouts(Some(10_000), None, Some(50))
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      limits.default(),
      timeouts,
      idle_port(),
    )
  owner.feed_chunk(stream, item_added())
  owner.feed_chunk(stream, text_delta("partial"))
  let assert Ok(stream_types.NextProgress(message.TextDelta(_, "partial"))) =
    owner.next(stream, None)
  let assert Ok(stream_types.StreamTerminal(
    stream_types.StreamFailed(error.DeadlineExceeded(error.IdleGap), evidence),
    _,
  )) = owner.next(stream, None)
  evidence.semantic_progress_observed |> should.be_true
}

pub fn owner_overall_deadline_test() {
  let timeouts = owner_provider_helper.timeouts(Some(50), None, None)
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      limits.default(),
      timeouts,
      idle_port(),
    )
  let assert Ok(stream_types.StreamTerminal(
    stream_types.StreamFailed(error.DeadlineExceeded(error.WholeCall), _),
    _,
  )) = owner.next(stream, None)
}

pub fn owner_cleanup_called_once_test() {
  let close_counter = process.new_subject()
  let port =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() {
      process.send(close_counter, 1)
    })
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      limits.default(),
      config.default_timeouts(),
      port,
    )

  owner.close(stream) |> should.equal(stream_types.ConsumerClosed)
  owner.close(stream) |> should.equal(stream_types.AlreadyTerminal)

  let assert Ok(1) = process.receive(close_counter, 1000)
  process.receive(close_counter, 50)
  |> should.be_error
}

pub fn owner_monitors_consumer_between_reads_test() {
  let close_counter = process.new_subject()
  let stream_subject = process.new_subject()
  process.spawn_unlinked(fn() {
    let transport =
      owner.TransportPort(request_more: fn() { Nil }, close: fn() {
        process.send(close_counter, Nil)
      })
    let assert Ok(stream) =
      owner_provider_helper.start_openai_stream(
        limits.default(),
        config.default_timeouts(),
        transport,
      )
    let assert Ok(pid) = owner.owner_pid(stream)
    process.send(stream_subject, #(stream, pid))
    Nil
  })

  let assert Ok(#(_stream, owner_pid)) = process.receive(stream_subject, 1000)
  let assert Ok(Nil) = process.receive(close_counter, 1000)
  wait_for_process_exit(owner_pid, 200)
  |> should.equal(True)
}

fn wait_for_process_exit(pid: process.Pid, attempts: Int) -> Bool {
  case process.is_alive(pid) {
    False -> True
    True ->
      case attempts > 0 {
        True -> {
          process.sleep(10)
          wait_for_process_exit(pid, attempts - 1)
        }
        False -> False
      }
  }
}

pub fn owner_keeps_one_outstanding_transport_credit_test() {
  let credit_counter = process.new_subject()
  let transport =
    owner.TransportPort(
      request_more: fn() { process.send(credit_counter, Nil) },
      close: fn() { Nil },
    )
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      limits.default(),
      config.default_timeouts(),
      transport,
    )

  // A bounded read (`next_within` at the facade) gives up with `ReadTimeout`.
  owner.next(stream, Some(10)) |> should.equal(Error(stream_types.ReadTimeout))
  owner.next(stream, Some(10)) |> should.equal(Error(stream_types.ReadTimeout))
  let assert Ok(Nil) = process.receive(credit_counter, 1000)
  process.receive(credit_counter, 50) |> should.be_error
  let _ = owner.close(stream)
  Nil
}

pub fn owner_read_timeout_delivery_race_never_loses_accepted_progress_test() {
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      limits.default(),
      config.default_timeouts(),
      idle_port(),
    )
  owner.feed_chunk(stream, item_added())
  process.spawn_unlinked(fn() {
    process.sleep(10)
    owner.feed_chunk(stream, text_delta("kept"))
  })

  case owner.next(stream, Some(10)) {
    Ok(stream_types.NextProgress(message.TextDelta(_, text))) ->
      text |> should.equal("kept")
    Error(stream_types.ReadTimeout) -> {
      let assert Ok(stream_types.NextProgress(message.TextDelta(_, text))) =
        owner.next(stream, Some(5000))
      text |> should.equal("kept")
    }
    _ -> should.fail()
  }
  let _ = owner.close(stream)
  Nil
}

pub fn owner_queue_limit_test() {
  let bounds = limits.Limits(..limits.default(), queue_count_limit: 2)
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      bounds,
      config.default_timeouts(),
      idle_port(),
    )

  owner.feed_chunk(stream, item_added())
  owner.feed_chunk(stream, text_delta("1"))
  owner.feed_chunk(stream, text_delta("2"))
  // The third queued delta breaches the queue count bound of 2.
  owner.feed_chunk(stream, text_delta("3"))

  let assert Ok(stream_types.NextProgress(message.TextDelta(_, "1"))) =
    owner.next(stream, Some(1000))
  let assert Ok(stream_types.NextProgress(message.TextDelta(_, "2"))) =
    owner.next(stream, Some(1000))
  let assert Ok(stream_types.StreamTerminal(
    stream_types.StreamFailed(error.LimitExceeded(limit.QueueCount, 2, 3), _),
    _,
  )) = owner.next(stream, Some(1000))
}

pub fn owner_response_body_limit_is_enforced_test() {
  let bounds = limits.Limits(..limits.default(), response_body_bytes_limit: 12)
  let assert Ok(stream) =
    owner_provider_helper.start_openai_stream(
      bounds,
      config.default_timeouts(),
      idle_port(),
    )
  owner.feed_chunk(stream, <<"1234567890123":utf8>>)
  let assert Ok(stream_types.StreamTerminal(
    stream_types.StreamFailed(
      error.LimitExceeded(limit.ResponseBodyBytes, 12, 13),
      _,
    ),
    _,
  )) = owner.next(stream, Some(1000))
}

pub fn owner_argument_disconnect_never_emits_partial_tool_call_test() {
  let calc = tool_fixtures.int_field_tool("calc", "x")
  let assert Ok(stream) =
    owner_provider_helper.start_anthropic_stream_with_tools(
      limits.default(),
      config.default_timeouts(),
      idle_port(),
      [calc],
    )
  owner.feed_chunk(stream, <<
    "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n":utf8,
  >>)
  owner.feed_chunk(stream, <<
    "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"calc\"}}\n\n":utf8,
  >>)
  owner.feed_chunk(stream, <<
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"x\\\":\"}}\n\n":utf8,
  >>)
  let reset =
    http_error.new(
      http_error.RequestFailed(http_error.ConnectionReset),
      http_error.MaybeSent,
    )
  owner.feed_failure(
    stream,
    error.Http(reset),
    stream_types.RetryEvidence(
      stream_types.RequestMayHaveReachedProvider,
      False,
      False,
    ),
  )
  // Progress may precede the failure (usage and, new in wave 4, the
  // tool-argument delta), but never a completed partial tool call.
  let assert Ok(failed) = read_to_terminal(stream)
  let assert stream_types.StreamFailed(error.Http(failure), _) = failed
  http_error.reason(failure)
  |> should.equal(http_error.RequestFailed(http_error.ConnectionReset))
}

fn read_to_terminal(
  stream: owner.Stream,
) -> Result(stream_types.TerminalOutcome, stream_types.ReadError) {
  case owner.next(stream, Some(1000)) {
    Ok(stream_types.NextProgress(message.ToolArgumentsDelta(..)))
    | Ok(stream_types.NextProgress(message.UsageUpdate(_))) ->
      read_to_terminal(stream)
    Ok(stream_types.NextProgress(other)) ->
      panic as { "unexpected progress " <> string.inspect(other) }
    Ok(stream_types.StreamTerminal(terminal, _)) -> Ok(terminal)
    Error(problem) -> Error(problem)
  }
}
