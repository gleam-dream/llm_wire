import gleam/erlang/process
import gleeunit/should
import llm_wire/owner
import llm_wire/types

pub fn owner_sequential_read_test() {
  let limits = types.default_limits()
  let deadlines = types.default_deadlines()

  let port =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })

  let assert Ok(stream) = owner.start_openai_stream(limits, deadlines, port)

  // Feed chunk with output item and text delta
  owner.feed_chunk(stream, <<
    "event: response.output_item.added\ndata: {\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\"}}\n\n":utf8,
  >>)
  owner.feed_chunk(stream, <<
    "event: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"Hi!\"}\n\n":utf8,
  >>)

  let assert Ok(types.NextProgress(types.TextDelta(block_id, text))) =
    owner.next(stream, 1000)
  block_id |> should.equal("item_1")
  text |> should.equal("Hi!")

  // Feed done and completed
  owner.feed_chunk(stream, <<
    "event: response.output_item.done\ndata: {\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\"}}\n\n":utf8,
  >>)
  owner.feed_chunk(stream, <<
    "event: response.completed\ndata: {\"response\": {\"id\": \"r1\", \"status\": \"completed\"}}\n\n":utf8,
  >>)

  let assert Ok(types.StreamTerminal(types.StreamFinished(outcome, _))) =
    owner.next(stream, 1000)
  outcome |> should.equal(types.CompletedText("Hi!"))

  // Subsequent read returns StreamClosed
  owner.next(stream, 1000)
  |> should.equal(Error(types.StreamClosed))
}

pub fn owner_copied_handles_and_close_test() {
  let limits = types.default_limits()
  let deadlines = types.default_deadlines()
  let port =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })

  let assert Ok(stream1) = owner.start_openai_stream(limits, deadlines, port)
  let stream2 = stream1

  // Close via stream1
  owner.close(stream1)
  |> should.equal(Ok(types.ConsumerClosed))

  // Close via stream2 returns AlreadyTerminal
  owner.close(stream2)
  |> should.equal(Ok(types.AlreadyTerminal))

  // Next on stream2 returns StreamClosed
  owner.next(stream2, 1000)
  |> should.equal(Error(types.StreamClosed))
}

pub fn owner_concurrent_read_conflict_test() {
  let limits = types.default_limits()
  let deadlines = types.default_deadlines()
  let port =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })

  let assert Ok(stream) = owner.start_openai_stream(limits, deadlines, port)

  // Start a background process that calls next (which will block waiting for data)
  let test_subject = process.new_subject()
  process.spawn_unlinked(fn() {
    let res = owner.next(stream, 2000)
    process.send(test_subject, res)
  })

  // Give the background process a moment to register its read
  process.sleep(30)

  // Now a concurrent read from the test process should fail immediately with ConcurrentReadConflict!
  owner.next(stream, 500)
  |> should.equal(Error(types.ConcurrentReadConflict))

  // Close stream to unblock background process
  owner.close(stream)
  |> should.equal(Ok(types.ConsumerClosed))
}

pub fn owner_idle_deadline_test() {
  let limits = types.default_limits()
  // Set very short idle deadline: 50ms
  let assert Ok(deadlines) =
    types.new_deadlines(
      overall_timeout_ms: 10_000,
      idle_timeout_ms: 50,
      read_timeout_ms: 1000,
    )
  let port =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })

  let assert Ok(stream) = owner.start_openai_stream(limits, deadlines, port)

  // Wait 100ms for idle timeout to trigger
  process.sleep(100)

  let res = owner.next(stream, 1000)
  case res {
    Ok(types.StreamTerminal(types.StreamFailed(
      types.DeadlineExceeded(types.IdleDeadline),
      _,
    ))) -> Nil
    _ -> panic as "expected IdleDeadline failure"
  }
}

pub fn owner_overall_deadline_test() {
  let limits = types.default_limits()
  // Set overall deadline to 50ms
  let assert Ok(deadlines) =
    types.new_deadlines(
      overall_timeout_ms: 50,
      idle_timeout_ms: 10_000,
      read_timeout_ms: 1000,
    )
  let port =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })

  let assert Ok(stream) = owner.start_openai_stream(limits, deadlines, port)

  // Wait 100ms for overall timeout to trigger
  process.sleep(100)

  let res = owner.next(stream, 1000)
  case res {
    Ok(types.StreamTerminal(types.StreamFailed(
      types.DeadlineExceeded(types.OverallDeadline),
      _,
    ))) -> Nil
    _ -> panic as "expected OverallDeadline failure"
  }
}

pub fn owner_cleanup_called_once_test() {
  let limits = types.default_limits()
  let deadlines = types.default_deadlines()

  let close_counter = process.new_subject()

  let port =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() {
      process.send(close_counter, 1)
    })

  let assert Ok(stream) = owner.start_openai_stream(limits, deadlines, port)

  // First close
  owner.close(stream)
  |> should.equal(Ok(types.ConsumerClosed))

  // Second close
  owner.close(stream)
  |> should.equal(Ok(types.AlreadyTerminal))

  // Check how many close calls were sent
  let assert Ok(1) = process.receive(close_counter, 100)
  // No second close message should be in mailbox
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
      owner.start_openai_stream(
        types.default_limits(),
        types.default_deadlines(),
        transport,
      )
    let assert Ok(pid) = owner.owner_pid(stream)
    process.send(stream_subject, #(stream, pid))
    Nil
  })

  let assert Ok(#(_stream, owner_pid)) = process.receive(stream_subject, 1000)
  let assert Ok(Nil) = process.receive(close_counter, 1000)
  process.is_alive(owner_pid) |> should.be_false
}

pub fn owner_keeps_one_outstanding_transport_credit_test() {
  let credit_counter = process.new_subject()
  let transport =
    owner.TransportPort(
      request_more: fn() { process.send(credit_counter, Nil) },
      close: fn() { Nil },
    )
  let assert Ok(stream) =
    owner.start_openai_stream(
      types.default_limits(),
      types.default_deadlines(),
      transport,
    )

  owner.next(stream, 10) |> should.equal(Error(types.ReadTimeout))
  owner.next(stream, 10) |> should.equal(Error(types.ReadTimeout))
  let assert Ok(Nil) = process.receive(credit_counter, 100)
  process.sleep(10)
  process.receive(credit_counter, 10) |> should.be_error
  let _ = owner.close(stream)
  Nil
}

pub fn owner_read_timeout_delivery_race_never_loses_accepted_progress_test() {
  let transport =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })
  let assert Ok(stream) =
    owner.start_openai_stream(
      types.default_limits(),
      types.default_deadlines(),
      transport,
    )
  owner.feed_chunk(stream, <<
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\",\"type\":\"message\"}}\n\n":utf8,
  >>)
  process.spawn_unlinked(fn() {
    process.sleep(10)
    owner.feed_chunk(stream, <<
      "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"item_1\",\"delta\":\"kept\"}\n\n":utf8,
    >>)
  })

  case owner.next(stream, 10) {
    Ok(types.NextProgress(types.TextDelta(_, text))) ->
      text |> should.equal("kept")
    Error(types.ReadTimeout) -> {
      let assert Ok(types.NextProgress(types.TextDelta(_, text))) =
        owner.next(stream, 1000)
      text |> should.equal("kept")
    }
    _ -> should.fail()
  }
  let _ = owner.close(stream)
  Nil
}

pub fn owner_queue_limit_test() {
  let assert Ok(limits) =
    types.new_limits(
      chunk_bytes_limit: 10_000,
      line_bytes_limit: 10_000,
      event_bytes_limit: 10_000,
      queue_count_limit: 2,
      queue_bytes_limit: 10_000,
      active_blocks_limit: 10,
      text_bytes_per_block_limit: 10_000,
      total_text_bytes_limit: 10_000,
      argument_bytes_per_call_limit: 10_000,
      total_argument_bytes_limit: 10_000,
      extension_bytes_limit: 10_000,
      response_body_bytes_limit: 10_000,
    )
  let deadlines = types.default_deadlines()
  let port =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })

  let assert Ok(stream) = owner.start_openai_stream(limits, deadlines, port)

  // Add block
  owner.feed_chunk(stream, <<
    "event: response.output_item.added\ndata: {\"output_index\": 0, \"item\": {\"id\": \"item_1\", \"type\": \"message\"}}\n\n":utf8,
  >>)
  // Feed delta 1 (enqueued)
  owner.feed_chunk(stream, <<
    "event: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"1\"}\n\n":utf8,
  >>)
  // Feed delta 2 (enqueued)
  owner.feed_chunk(stream, <<
    "event: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"2\"}\n\n":utf8,
  >>)
  // Feed delta 3 (should breach queue_count_limit of 2!)
  owner.feed_chunk(stream, <<
    "event: response.output_text.delta\ndata: {\"output_index\": 0, \"item_id\": \"item_1\", \"delta\": \"3\"}\n\n":utf8,
  >>)

  let assert Ok(types.NextProgress(types.TextDelta(_, "1"))) =
    owner.next(stream, 1000)
  let assert Ok(types.NextProgress(types.TextDelta(_, "2"))) =
    owner.next(stream, 1000)

  // Next item must be the limit failure!
  let res = owner.next(stream, 1000)
  case res {
    Ok(types.StreamTerminal(types.StreamFailed(
      types.ResourceLimitExceeded("queue_count_limit", 2, 3),
      _,
    ))) -> Nil
    _other -> panic as "expected queue_count_limit ResourceLimitExceeded"
  }
}

pub fn owner_response_body_limit_is_enforced_test() {
  let limits =
    types.Limits(..types.default_limits(), response_body_bytes_limit: 12)
  let transport =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })
  let assert Ok(stream) =
    owner.start_openai_stream(limits, types.default_deadlines(), transport)
  owner.feed_chunk(stream, <<"1234567890123":utf8>>)
  case owner.next(stream, 1000) {
    Ok(types.StreamTerminal(types.StreamFailed(
      types.ResourceLimitExceeded("response_body_bytes_limit", 12, 13),
      _,
    ))) -> should.be_true(True)
    _ -> should.fail()
  }
}
