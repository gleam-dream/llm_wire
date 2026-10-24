//// The per-call owner process. It frames SSE, steps the reducer, bounds
//// every queue and text, runs the call's three timers and delivers progress
//// to exactly one reader at a time. It monitors the caller: caller death
//// releases the HTTP stream.

import gleam/bit_array
import gleam/erlang/process
import gleam/erlang/reference
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import llm_wire/error
import llm_wire/internal/adapter
import llm_wire/internal/call_admission
import llm_wire/internal/config.{type Timeouts}
import llm_wire/internal/limits.{type Limits}
import llm_wire/internal/observe
import llm_wire/internal/sse
import llm_wire/internal/stream_types.{
  type ReadError, type ReadResult, type RetryClassification,
  type TerminalOutcome,
}
import llm_wire/internal/tool_def
import llm_wire/limit
import llm_wire/message
import llm_wire/telemetry
import llm_wire/tool

pub opaque type Stream {
  Stream(subject: process.Subject(Message))
}

pub type TransportPort {
  TransportPort(request_more: fn() -> Nil, close: fn() -> Nil)
}

/// Everything one execution's owner needs.
pub type Setup {
  Setup(
    context: observe.Context,
    reducer: adapter.Reducer,
    limits: Limits,
    timeouts: Timeouts,
    tools: List(tool_def.Tool),
    checks: tool.ToolCallChecks,
  )
}

type Message {
  Next(
    read_id: reference.Reference,
    reply_to: process.Subject(Result(ReadResult, ReadError)),
    consumer_pid: process.Pid,
  )
  Close(reply_to: process.Subject(stream_types.CloseOutcome))
  CancelPendingRead(
    read_id: reference.Reference,
    reply_to: process.Subject(CancelPendingReadResult),
  )
  FeedChunk(chunk: BitArray)
  FeedEof
  FeedFailure(error.Error, stream_types.RetryEvidence)
  RequestWasSent
  ResponseBytesObserved
  TimerFired(timeout: error.Timeout)
  DownMessage(process.Down)
}

type State {
  State(
    self_subject: process.Subject(Message),
    context: observe.Context,
    limits: Limits,
    timeouts: Timeouts,
    framer: sse.Framer,
    reducer: adapter.Reducer,
    admitted_tools: List(tool_def.Tool),
    tool_call_checks: tool.ToolCallChecks,
    queue: List(ReadResult),
    queue_count: Int,
    queue_bytes: Int,
    pending_read: Option(PendingRead),
    transport: TransportPort,
    transport_closed: Bool,
    whole_call_timer: Option(process.Timer),
    first_token_timer: Option(process.Timer),
    idle_timer: Option(process.Timer),
    terminal_outcome: Option(TerminalOutcome),
    request_sent: Bool,
    response_bytes_observed: Bool,
    response_bytes_received: Int,
    semantic_progress_observed: Bool,
    progress_text_bytes: Int,
    progress_blocks: List(#(String, Int)),
    outstanding_read_credit: Bool,
    last_usage: Option(message.Usage),
    consumer_monitor: process.Monitor,
  )
}

type PendingRead {
  PendingRead(
    read_id: reference.Reference,
    caller: process.Subject(Result(ReadResult, ReadError)),
    consumer_pid: process.Pid,
    monitor: process.Monitor,
  )
}

type CancelPendingReadResult {
  CancelWon
  DeliveryWon
}

pub fn is_alive(stream: Stream) -> Bool {
  case owner_pid(stream) {
    Ok(pid) -> process.is_alive(pid)
    Error(Nil) -> False
  }
}

pub fn owner_pid(stream: Stream) -> Result(process.Pid, Nil) {
  process.subject_owner(stream.subject)
}

/// Starts the owner. `whole_call_ms` is the time left in the call's budget,
/// or `None` when the whole call is unbounded. The transport starts inside
/// the owner, so its linked worker shares the owner's lifetime.
pub fn start(
  setup: Setup,
  whole_call_ms: Option(Int),
  start_transport: fn(Stream) -> TransportPort,
) -> Result(Stream, Nil) {
  let consumer_pid = process.self()
  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      let transport = start_transport(Stream(subject))
      let whole_call_timer =
        option.map(whole_call_ms, fn(ms) {
          process.send_after(subject, ms, TimerFired(error.WholeCall))
        })
      let first_token_timer =
        option.map(setup.timeouts.first_token, fn(ms) {
          process.send_after(subject, ms, TimerFired(error.FirstToken))
        })
      let consumer_monitor = process.monitor(consumer_pid)
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(DownMessage)
      let initial_state =
        State(
          self_subject: subject,
          context: setup.context,
          limits: setup.limits,
          timeouts: setup.timeouts,
          framer: sse.new(setup.limits),
          reducer: setup.reducer,
          admitted_tools: setup.tools,
          tool_call_checks: setup.checks,
          queue: [],
          queue_count: 0,
          queue_bytes: 0,
          pending_read: None,
          transport: transport,
          transport_closed: False,
          whole_call_timer:,
          first_token_timer:,
          idle_timer: None,
          terminal_outcome: None,
          request_sent: False,
          response_bytes_observed: False,
          response_bytes_received: 0,
          semantic_progress_observed: False,
          progress_text_bytes: 0,
          progress_blocks: [],
          outstanding_read_credit: True,
          last_usage: None,
          consumer_monitor: consumer_monitor,
        )
      transport.request_more()
      actor.initialised(initial_state)
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle_message)
  case actor.start(builder) {
    Ok(started) -> Ok(Stream(started.data))
    Error(_) -> Error(Nil)
  }
}

type ReadWait {
  Delivered(Result(ReadResult, ReadError))
  OwnerStopped
}

type CancelWait {
  CancelAcknowledged(CancelPendingReadResult)
  OwnerFinished
}

/// Waits for the next item. `None` waits until one arrives: the owner's
/// timers bound that wait. `Some(ms)` gives up after `ms` with
/// `ReadTimeout` and keeps the stream readable.
pub fn next(
  stream: Stream,
  timeout_ms: Option(Int),
) -> Result(ReadResult, ReadError) {
  case owner_pid(stream) {
    Error(Nil) -> Error(stream_types.StreamClosed)
    Ok(pid) ->
      case process.is_alive(pid) {
        False -> Error(stream_types.StreamClosed)
        True -> {
          let monitor = process.monitor(pid)
          let reply_to = process.new_subject()
          let read_id = reference.new()
          process.send(stream.subject, Next(read_id, reply_to, process.self()))
          let selector =
            process.new_selector()
            |> process.select_map(reply_to, Delivered)
            |> process.select_specific_monitor(monitor, fn(_) { OwnerStopped })
          let received = case timeout_ms {
            None -> Ok(process.selector_receive_forever(selector))
            Some(ms) -> process.selector_receive(selector, ms)
          }
          let result = case received {
            Ok(Delivered(result)) -> result
            Ok(OwnerStopped) -> delivered_before_exit(reply_to)
            Error(Nil) -> {
              let cancelled = process.new_subject()
              process.send(
                stream.subject,
                CancelPendingRead(read_id, cancelled),
              )
              // Await the acknowledgement to avoid leaving a late reply in the
              // caller mailbox. A terminal owner may exit instead of replying
              // to this cancellation; its previously sent result wins.
              case
                process.new_selector()
                |> process.select_map(cancelled, CancelAcknowledged)
                |> process.select_specific_monitor(monitor, fn(_) {
                  OwnerFinished
                })
                |> process.selector_receive(5000)
              {
                Ok(CancelAcknowledged(CancelWon)) ->
                  Error(stream_types.ReadTimeout)
                Ok(CancelAcknowledged(DeliveryWon)) | Ok(OwnerFinished) ->
                  delivered_before_exit(reply_to)
                Error(Nil) -> Error(stream_types.OwnerUnavailable)
              }
            }
          }
          process.demonitor_process(monitor)
          result
        }
      }
  }
}

fn delivered_before_exit(
  reply: process.Subject(Result(ReadResult, ReadError)),
) -> Result(ReadResult, ReadError) {
  case process.receive(reply, 0) {
    Ok(value) -> value
    Error(Nil) -> Error(stream_types.OwnerUnavailable)
  }
}

/// Ends the call. Idempotent; an owner that does not answer within 5 s is
/// killed, which also ends its transport worker.
pub fn close(stream: Stream) -> stream_types.CloseOutcome {
  case owner_pid(stream) {
    Error(Nil) -> stream_types.AlreadyTerminal
    Ok(pid) -> {
      let monitor = process.monitor(pid)
      let reply_to = process.new_subject()
      process.send(stream.subject, Close(reply_to: reply_to))
      let outcome = case
        process.new_selector()
        |> process.select_map(reply_to, Some)
        |> process.select_specific_monitor(monitor, fn(_) { None })
        |> process.selector_receive(5000)
      {
        Ok(Some(outcome)) -> outcome
        Ok(None) ->
          process.receive(reply_to, 0)
          |> result.unwrap(stream_types.AlreadyTerminal)
        Error(Nil) -> {
          process.kill(pid)
          stream_types.ConsumerClosed
        }
      }
      process.demonitor_process(monitor)
      outcome
    }
  }
}

pub fn feed_chunk(stream: Stream, chunk: BitArray) -> Nil {
  process.send(stream.subject, FeedChunk(chunk))
}

pub fn feed_eof(stream: Stream) -> Nil {
  process.send(stream.subject, FeedEof)
}

pub fn feed_failure(
  stream: Stream,
  failure: error.Error,
  retry: stream_types.RetryEvidence,
) -> Nil {
  process.send(stream.subject, FeedFailure(failure, retry))
}

pub fn request_was_sent(stream: Stream) -> Nil {
  process.send(stream.subject, RequestWasSent)
}

pub fn response_bytes_observed(stream: Stream) -> Nil {
  process.send(stream.subject, ResponseBytesObserved)
}

fn handle_message(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Next(read_id, reply_to, caller_pid) ->
      handle_next(state, read_id, reply_to, caller_pid)
    Close(reply_to) -> handle_close(state, reply_to)
    CancelPendingRead(read_id, reply_to) ->
      case state.pending_read {
        Some(pending) if pending.read_id == read_id -> {
          process.demonitor_process(pending.monitor)
          process.send(reply_to, CancelWon)
          actor.continue(State(..state, pending_read: None))
        }
        _ -> {
          process.send(reply_to, DeliveryWon)
          actor.continue(state)
        }
      }
    FeedChunk(chunk) -> handle_chunk(state, chunk)
    FeedEof -> handle_eof(state)
    FeedFailure(failure, retry) ->
      case state.terminal_outcome {
        Some(_) -> actor.continue(state)
        None -> {
          let cleaned = perform_cleanup(state)
          let evidence =
            merge_evidence(
              retry,
              state.response_bytes_observed,
              state.semantic_progress_observed,
            )
          finish(cleaned, stream_types.StreamFailed(failure, evidence))
        }
      }
    RequestWasSent -> {
      observe.emit(
        state.context,
        telemetry.RequestSent,
        telemetry.ResponseStarted,
      )
      actor.continue(State(..state, request_sent: True))
    }
    ResponseBytesObserved ->
      actor.continue(State(..state, response_bytes_observed: True))
    TimerFired(timeout) -> handle_timer(state, timeout)
    DownMessage(down) -> handle_down(state, down)
  }
}

fn handle_next(
  state: State,
  read_id: reference.Reference,
  reply_to: process.Subject(Result(ReadResult, ReadError)),
  caller_pid: process.Pid,
) -> actor.Next(State, Message) {
  let state = case state.pending_read {
    Some(pending) if pending.consumer_pid == caller_pid -> {
      process.demonitor_process(pending.monitor)
      State(..state, pending_read: None)
    }
    _ -> state
  }
  case state.pending_read {
    Some(_) -> {
      process.send(reply_to, Error(stream_types.ConcurrentReadConflict))
      actor.continue(state)
    }
    None ->
      case state.queue {
        [head, ..tail] -> {
          process.send(reply_to, Ok(head))
          let updated =
            State(
              ..state,
              queue: tail,
              queue_count: state.queue_count - 1,
              queue_bytes: state.queue_bytes - size_of_result(head),
            )
          if_needed_request_bytes(updated)
        }
        [] ->
          case state.terminal_outcome {
            Some(terminal) -> {
              process.send(reply_to, Ok(terminal_result(state, terminal)))
              let _ = perform_cleanup(state)
              actor.stop()
            }
            None -> {
              let monitor = process.monitor(caller_pid)
              let pending = PendingRead(read_id, reply_to, caller_pid, monitor)
              if_needed_request_bytes(
                State(..state, pending_read: Some(pending)),
              )
            }
          }
      }
  }
}

fn terminal_result(state: State, terminal: TerminalOutcome) -> ReadResult {
  stream_types.StreamTerminal(terminal, state.last_usage)
}

fn handle_close(
  state: State,
  reply_to: process.Subject(stream_types.CloseOutcome),
) -> actor.Next(State, Message) {
  case state.terminal_outcome {
    Some(_) -> {
      process.send(reply_to, stream_types.AlreadyTerminal)
      let _ = perform_cleanup(state)
      actor.stop()
    }
    None -> {
      let cleaned = perform_cleanup(state)
      observe.emit(state.context, telemetry.Cancelled, telemetry.ConsumerClosed)
      let outcome =
        stream_types.StreamCancelledLocally(evidence(
          cleaned,
          classification_after_send(cleaned),
        ))
      case cleaned.pending_read {
        Some(pending) -> {
          process.demonitor_process(pending.monitor)
          process.send(pending.caller, Ok(terminal_result(cleaned, outcome)))
        }
        None -> Nil
      }
      process.send(reply_to, stream_types.ConsumerClosed)
      actor.stop()
    }
  }
}

fn handle_chunk(state: State, chunk: BitArray) -> actor.Next(State, Message) {
  case state.terminal_outcome {
    Some(_) -> actor.continue(state)
    None -> {
      let received = state.response_bytes_received + bit_array.byte_size(chunk)
      let with_bytes =
        State(
          ..state,
          response_bytes_observed: True,
          response_bytes_received: received,
          outstanding_read_credit: False,
        )
      case received > state.limits.response_body_bytes_limit {
        True ->
          fail_stream(
            with_bytes,
            error.LimitExceeded(
              limit.ResponseBodyBytes,
              state.limits.response_body_bytes_limit,
              received,
            ),
          )
        False ->
          case sse.feed(with_bytes.framer, chunk) {
            Error(problem) -> fail_stream(with_bytes, problem)
            Ok(#(next_framer, events)) ->
              process_sse_events(
                State(..with_bytes, framer: next_framer),
                events,
              )
          }
      }
    }
  }
}

fn process_sse_events(
  state: State,
  events: List(sse.ServerSentEvent),
) -> actor.Next(State, Message) {
  case events {
    [] -> if_needed_request_bytes(state)
    [event, ..rest] -> {
      // Any provider event, a ping included, shows the stream is alive.
      let state = touch_idle_timer(state)
      case state.reducer.step(event) {
        Error(problem) -> fail_stream(state, problem)
        Ok(#(next_reducer, progress)) ->
          case
            ingest_progress(State(..state, reducer: next_reducer), progress)
          {
            Error(#(partial, problem)) -> fail_stream(partial, problem)
            Ok(after) ->
              case terminal_provider(after) {
                Ok(Some(terminal)) -> finish(perform_cleanup(after), terminal)
                Ok(None) -> process_sse_events(after, rest)
                Error(problem) -> fail_completed(after, problem)
              }
          }
      }
    }
  }
}

fn ingest_progress(
  state: State,
  progress_list: List(message.Progress),
) -> Result(State, #(State, error.Error)) {
  list.try_fold(progress_list, state, fn(current, progress) {
    use validated <- result.try(
      validate_progress(current, progress)
      |> result.map_error(fn(problem) { #(current, problem) }),
    )
    let size = size_of_progress(progress)
    use Nil <- result.try(
      case validated.queue_count + 1 > validated.limits.queue_count_limit {
        True ->
          Error(#(
            current,
            error.LimitExceeded(
              limit.QueueCount,
              validated.limits.queue_count_limit,
              validated.queue_count + 1,
            ),
          ))
        False -> Ok(Nil)
      },
    )
    use Nil <- result.try(
      case validated.queue_bytes + size > validated.limits.queue_bytes_limit {
        True ->
          Error(#(
            current,
            error.LimitExceeded(
              limit.QueueBytes,
              validated.limits.queue_bytes_limit,
              validated.queue_bytes + size,
            ),
          ))
        False -> Ok(Nil)
      },
    )
    let with_usage = case progress {
      message.UsageUpdate(usage) -> State(..validated, last_usage: Some(usage))
      _ -> validated
    }
    let observed = case is_semantic_progress(progress) {
      True -> first_progress(with_usage)
      False -> with_usage
    }
    Ok(dispatch_or_queue_progress(observed, progress, size))
  })
}

/// The first progress event ends the first-token timer and starts the idle
/// gap.
fn first_progress(state: State) -> State {
  case state.semantic_progress_observed {
    True -> state
    False -> {
      cancel(state.first_token_timer)
      observe.emit(state.context, telemetry.FirstProgress, telemetry.Received)
      touch_idle_timer(
        State(
          ..state,
          semantic_progress_observed: True,
          first_token_timer: None,
        ),
      )
    }
  }
}

fn validate_progress(
  state: State,
  progress: message.Progress,
) -> Result(State, error.Error) {
  case progress {
    message.TextDelta(block_id, text) ->
      add_progress_text(state, "text:" <> block_id, text)
    message.RefusalDelta(block_id, text) ->
      add_progress_text(state, "refusal:" <> block_id, text)
    message.ReasoningDelta(block_id, text) ->
      add_progress_text(state, "reasoning:" <> block_id, text)
    // Reducers bound argument bytes per call and in total.
    message.ToolArgumentsDelta(..) -> Ok(state)
    message.UsageUpdate(_) -> Ok(state)
    message.ProviderExtension(provider_name, event_name) -> {
      let bytes = string.byte_size(provider_name) + string.byte_size(event_name)
      case bytes > state.limits.extension_bytes_limit {
        True ->
          Error(error.LimitExceeded(
            limit.ExtensionBytes,
            state.limits.extension_bytes_limit,
            bytes,
          ))
        False -> Ok(state)
      }
    }
  }
}

fn add_progress_text(
  state: State,
  block_key: String,
  text: String,
) -> Result(State, error.Error) {
  let delta_bytes = string.byte_size(text)
  let prior = case list.key_find(state.progress_blocks, block_key) {
    Ok(bytes) -> bytes
    Error(Nil) -> 0
  }
  let block_bytes = prior + delta_bytes
  let total_bytes = state.progress_text_bytes + delta_bytes
  let blocks = list.key_set(state.progress_blocks, block_key, block_bytes)
  case
    block_bytes > state.limits.text_bytes_per_block_limit,
    total_bytes > state.limits.total_text_bytes_limit,
    list.length(blocks) > state.limits.active_blocks_limit
  {
    True, _, _ ->
      Error(error.LimitExceeded(
        limit.TextBytesPerBlock,
        state.limits.text_bytes_per_block_limit,
        block_bytes,
      ))
    _, True, _ ->
      Error(error.LimitExceeded(
        limit.TotalTextBytes,
        state.limits.total_text_bytes_limit,
        total_bytes,
      ))
    _, _, True ->
      Error(error.LimitExceeded(
        limit.ActiveBlocks,
        state.limits.active_blocks_limit,
        list.length(blocks),
      ))
    False, False, False ->
      Ok(
        State(
          ..state,
          progress_text_bytes: total_bytes,
          progress_blocks: blocks,
        ),
      )
  }
}

fn dispatch_or_queue_progress(
  state: State,
  progress: message.Progress,
  size: Int,
) -> State {
  case state.pending_read {
    Some(pending) if state.queue == [] -> {
      process.demonitor_process(pending.monitor)
      process.send(pending.caller, Ok(stream_types.NextProgress(progress)))
      State(..state, pending_read: None)
    }
    _ ->
      State(
        ..state,
        queue: list.append(state.queue, [stream_types.NextProgress(progress)]),
        queue_count: state.queue_count + 1,
        queue_bytes: state.queue_bytes + size,
      )
  }
}

/// Records the terminal and delivers it when a reader waits and no progress
/// is queued ahead of it. The terminal has its own slot, outside the
/// bounded progress queue.
fn finish(
  state: State,
  terminal: TerminalOutcome,
) -> actor.Next(State, Message) {
  let state = case terminal {
    stream_types.StreamFinished(_, Some(usage)) ->
      State(..state, last_usage: Some(usage))
    _ -> state
  }
  observe.emit(
    state.context,
    telemetry.Terminal,
    terminal_outcome_name(terminal),
  )
  let state = State(..state, terminal_outcome: Some(terminal))
  case state.pending_read {
    Some(pending) if state.queue == [] -> {
      process.demonitor_process(pending.monitor)
      process.send(pending.caller, Ok(terminal_result(state, terminal)))
      let _ = perform_cleanup(state)
      actor.stop()
    }
    _ -> actor.continue(state)
  }
}

fn fail_stream(
  state: State,
  problem: error.Error,
) -> actor.Next(State, Message) {
  let cleaned = perform_cleanup(state)
  finish(
    cleaned,
    stream_types.StreamFailed(
      problem,
      evidence(cleaned, classification_after_send(cleaned)),
    ),
  )
}

/// A failure found after the provider finished its response, such as a
/// tool call that fails admission.
fn fail_completed(
  state: State,
  problem: error.Error,
) -> actor.Next(State, Message) {
  let cleaned = perform_cleanup(state)
  finish(
    cleaned,
    stream_types.StreamFailed(
      problem,
      evidence(cleaned, stream_types.ResponseCompleted),
    ),
  )
}

/// The worker sends the request as soon as the owner starts, so a failure
/// inside the owner may follow a request the provider received.
fn classification_after_send(_state: State) -> RetryClassification {
  stream_types.RequestMayHaveReachedProvider
}

fn evidence(
  state: State,
  classification: RetryClassification,
) -> stream_types.RetryEvidence {
  stream_types.RetryEvidence(
    classification:,
    response_bytes_observed: state.response_bytes_observed,
    semantic_progress_observed: state.semantic_progress_observed,
  )
}

fn merge_evidence(
  reported: stream_types.RetryEvidence,
  response_bytes: Bool,
  semantic_progress: Bool,
) -> stream_types.RetryEvidence {
  stream_types.RetryEvidence(
    ..reported,
    response_bytes_observed: reported.response_bytes_observed || response_bytes,
    semantic_progress_observed: reported.semantic_progress_observed
      || semantic_progress,
  )
}

fn handle_eof(state: State) -> actor.Next(State, Message) {
  case state.terminal_outcome {
    Some(_) -> actor.continue(state)
    None ->
      case sse.finish(state.framer) {
        Error(problem) -> fail_stream(state, problem)
        Ok(_) -> end_of_stream(state)
      }
  }
}

fn end_of_stream(state: State) -> actor.Next(State, Message) {
  case terminal_provider(state) {
    Ok(Some(outcome)) -> finish(perform_cleanup(state), outcome)
    Ok(None) ->
      fail_stream(
        state,
        error.Protocol("Unexpected EOF before stream completed"),
      )
    Error(problem) -> fail_completed(state, problem)
  }
}

fn handle_timer(
  state: State,
  timeout: error.Timeout,
) -> actor.Next(State, Message) {
  case state.terminal_outcome {
    Some(_) -> actor.continue(state)
    None -> {
      observe.emit(state.context, telemetry.Deadline, case timeout {
        error.WholeCall -> telemetry.WholeCallExpired
        error.FirstToken -> telemetry.FirstTokenExpired
        error.IdleGap -> telemetry.IdleGapExpired
      })
      fail_stream(state, error.DeadlineExceeded(timeout))
    }
  }
}

fn handle_down(state: State, down: process.Down) -> actor.Next(State, Message) {
  case down {
    process.ProcessDown(..) -> {
      let _ = perform_cleanup(state)
      actor.stop()
    }
    _ -> actor.continue(state)
  }
}

/// Restarts the idle-gap timer once the first progress event arrived.
fn touch_idle_timer(state: State) -> State {
  case state.semantic_progress_observed, state.terminal_outcome {
    True, None -> {
      cancel(state.idle_timer)
      State(
        ..state,
        idle_timer: option.map(state.timeouts.idle_gap, fn(ms) {
          process.send_after(state.self_subject, ms, TimerFired(error.IdleGap))
        }),
      )
    }
    _, _ -> state
  }
}

fn cancel(timer: Option(process.Timer)) -> Nil {
  case timer {
    Some(t) -> {
      process.cancel_timer(t)
      Nil
    }
    None -> Nil
  }
}

fn perform_cleanup(state: State) -> State {
  case state.transport_closed {
    True -> state
    False -> {
      cancel(state.whole_call_timer)
      cancel(state.first_token_timer)
      cancel(state.idle_timer)
      state.transport.close()
      observe.emit(state.context, telemetry.Cleanup, telemetry.TransportClosed)
      State(
        ..state,
        transport_closed: True,
        whole_call_timer: None,
        first_token_timer: None,
        idle_timer: None,
      )
    }
  }
}

fn terminal_outcome_name(terminal: TerminalOutcome) -> telemetry.Outcome {
  case terminal {
    stream_types.StreamFinished(stream_types.CompletedText(_), _) ->
      telemetry.Answered
    stream_types.StreamFinished(stream_types.Refused(_), _) -> telemetry.Refused
    stream_types.StreamFinished(stream_types.CompletedToolCalls(..), _)
    | stream_types.StreamFinished(
        stream_types.CompletedToolCallsWithData(..),
        _,
      ) -> telemetry.ToolsRequested
    stream_types.StreamFinished(stream_types.OutputLimited(_, _), _) ->
      telemetry.OutputLimited
    stream_types.StreamFailed(_, _) -> telemetry.Failed
    stream_types.StreamCancelledLocally(_) -> telemetry.CallCancelled
  }
}

fn if_needed_request_bytes(state: State) -> actor.Next(State, Message) {
  case state.terminal_outcome, state.transport_closed {
    None, False ->
      case
        !state.outstanding_read_credit
        && {
          state.queue_count == 0
          || state.queue_count < state.limits.queue_count_limit / 2
        }
      {
        True -> {
          state.transport.request_more()
          actor.continue(State(..state, outstanding_read_credit: True))
        }
        False -> actor.continue(state)
      }
    _, _ -> actor.continue(state)
  }
}

fn terminal_provider(
  state: State,
) -> Result(Option(TerminalOutcome), error.Error) {
  case state.reducer.terminal() {
    None -> Ok(None)
    Some(adapter.Text(text, usage)) ->
      call_admission.validate_text(state.limits, text)
      |> result.map(fn(_) {
        Some(stream_types.StreamFinished(
          stream_types.CompletedText(text),
          usage,
        ))
      })
    Some(adapter.ToolCalls(text, calls, response_id, provider_data, usage)) -> {
      use Nil <- result.try(call_admission.validate_text(state.limits, text))
      use Nil <- result.try(call_admission.validate_metadata(
        state.limits,
        calls,
        response_id,
        provider_data,
      ))
      use issues <- result.try(call_admission.admit(
        calls,
        state.admitted_tools,
        state.limits,
        state.tool_call_checks,
      ))
      Ok(
        Some(case provider_data {
          None ->
            stream_types.StreamFinished(
              stream_types.CompletedToolCalls(text, calls, response_id, issues),
              usage,
            )
          Some(value) ->
            stream_types.StreamFinished(
              stream_types.CompletedToolCallsWithData(
                text,
                calls,
                response_id,
                value,
                issues,
              ),
              usage,
            )
        }),
      )
    }
    Some(adapter.OutputLimited(text, calls, usage)) -> {
      use Nil <- result.try(call_admission.validate_text(state.limits, text))
      use Nil <- result.try(call_admission.validate_metadata(
        state.limits,
        calls,
        None,
        None,
      ))
      use Nil <- result.try(validate_partial_calls(state.limits, calls))
      Ok(
        Some(stream_types.StreamFinished(
          stream_types.OutputLimited(text, calls),
          usage,
        )),
      )
    }
    Some(adapter.Refusal(reason, usage)) ->
      call_admission.validate_text(state.limits, reason)
      |> result.map(fn(_) {
        Some(stream_types.StreamFinished(stream_types.Refused(reason), usage))
      })
    Some(adapter.Failed(problem, _usage)) ->
      Ok(
        Some(stream_types.StreamFailed(
          problem,
          evidence(state, stream_types.ResponseCompleted),
        )),
      )
  }
}

fn validate_partial_calls(
  limits: Limits,
  calls: List(message.ToolCall),
) -> Result(Nil, error.Error) {
  let count = list.length(calls)
  use Nil <- result.try(case count > limits.active_blocks_limit {
    True ->
      Error(error.LimitExceeded(
        limit.ActiveBlocks,
        limits.active_blocks_limit,
        count,
      ))
    False -> Ok(Nil)
  })
  list.try_fold(calls, 0, fn(prior, call) {
    let bytes = string.byte_size(call.arguments_json)
    use Nil <- result.try(case bytes > limits.argument_bytes_per_call_limit {
      True ->
        Error(error.LimitExceeded(
          limit.ArgumentBytesPerCall,
          limits.argument_bytes_per_call_limit,
          bytes,
        ))
      False -> Ok(Nil)
    })
    let total = prior + bytes
    case total > limits.total_argument_bytes_limit {
      True ->
        Error(error.LimitExceeded(
          limit.TotalArgumentBytes,
          limits.total_argument_bytes_limit,
          total,
        ))
      False -> Ok(total)
    }
  })
  |> result.replace(Nil)
}

/// Content the model produced. Usage reports and unrecognized events do
/// not end the first-token wait and are not partial output.
fn is_semantic_progress(progress: message.Progress) -> Bool {
  case progress {
    message.ProviderExtension(_, _) | message.UsageUpdate(_) -> False
    _ -> True
  }
}

fn size_of_result(result: ReadResult) -> Int {
  case result {
    stream_types.NextProgress(p) -> size_of_progress(p)
    stream_types.StreamTerminal(..) -> 64
  }
}

fn size_of_progress(progress: message.Progress) -> Int {
  case progress {
    message.TextDelta(id, t)
    | message.RefusalDelta(id, t)
    | message.ReasoningDelta(id, t)
    | message.ToolArgumentsDelta(id, t) ->
      string.byte_size(id) + string.byte_size(t) + 32
    message.UsageUpdate(_) -> 24
    message.ProviderExtension(provider_name, e) ->
      string.byte_size(provider_name) + string.byte_size(e) + 16
  }
}
