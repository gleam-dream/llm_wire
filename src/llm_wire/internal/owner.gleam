import gleam/bit_array
import gleam/erlang/process
import gleam/erlang/reference
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import llm_wire/internal/call_admission
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/internal/transport_failure
import llm_wire/provider
import llm_wire/telemetry
import llm_wire/types

pub opaque type Stream {
  Stream(subject: process.Subject(Message))
}

pub type TransportPort {
  TransportPort(request_more: fn() -> Nil, close: fn() -> Nil)
}

pub fn start_provider_stream(
  identity: types.Provider,
  reducer: provider.Reducer,
  limits: types.Limits,
  deadlines: types.Deadlines,
  transport: TransportPort,
  tools: List(types.ToolDefinition),
  checks: types.ToolCallChecks,
) -> Result(Stream, types.WireError) {
  start_stream(identity, reducer, limits, deadlines, transport, tools, checks)
}

type Message {
  Next(
    read_id: reference.Reference,
    reply_to: process.Subject(Result(stream_types.ReadResult, types.ReadError)),
    consumer_pid: process.Pid,
  )
  Close(reply_to: process.Subject(types.CloseOutcome))
  CancelPendingRead(
    read_id: reference.Reference,
    reply_to: process.Subject(CancelPendingReadResult),
  )
  FeedChunk(chunk: BitArray)
  FeedEof
  FeedError(failure: transport_failure.Failure)
  AttachTransport(transport: TransportPort)
  RequestWasSent
  OverallDeadlineFired
  IdleDeadlineFired
  DownMessage(process.Down)
}

type State {
  State(
    self_subject: process.Subject(Message),
    limits: types.Limits,
    deadlines: types.Deadlines,
    framer: sse.Framer,
    provider: provider.Reducer,
    provider_identity: types.Provider,
    admitted_tools: List(types.ToolDefinition),
    tool_call_checks: types.ToolCallChecks,
    queue: List(stream_types.ReadResult),
    queue_count: Int,
    queue_bytes: Int,
    pending_read: Option(PendingRead),
    transport: TransportPort,
    transport_closed: Bool,
    overall_timer: Option(process.Timer),
    idle_timer: Option(process.Timer),
    terminal_outcome: Option(stream_types.TerminalOutcome),
    terminal_delivered: Bool,
    response_bytes_observed: Bool,
    response_bytes_received: Int,
    semantic_progress_observed: Bool,
    first_progress_observed: Bool,
    progress_text_bytes: Int,
    progress_blocks: List(#(String, Int)),
    outstanding_read_credit: Bool,
    consumer_monitor: process.Monitor,
  )
}

type PendingRead {
  PendingRead(
    read_id: reference.Reference,
    caller: process.Subject(Result(stream_types.ReadResult, types.ReadError)),
    consumer_pid: process.Pid,
    monitor: process.Monitor,
  )
}

type CancelPendingReadResult {
  CancelWon
  DeliveryWon
}

pub fn is_alive(stream: Stream) -> Bool {
  let Stream(subject) = stream
  case process.subject_owner(subject) {
    Ok(pid) -> process.is_alive(pid)
    Error(Nil) -> False
  }
}

pub fn owner_pid(stream: Stream) -> Result(process.Pid, Nil) {
  let Stream(subject) = stream
  process.subject_owner(subject)
}

fn start_stream(
  identity: types.Provider,
  reducer: provider.Reducer,
  limits: types.Limits,
  deadlines: types.Deadlines,
  transport: TransportPort,
  tools: List(types.ToolDefinition),
  checks: types.ToolCallChecks,
) -> Result(Stream, types.WireError) {
  let consumer_pid = process.self()
  let builder =
    actor.new_with_initialiser(5000, fn(subject) {
      let overall_timer = case deadlines.overall_timeout_ms > 0 {
        True ->
          Some(process.send_after(
            subject,
            deadlines.overall_timeout_ms,
            OverallDeadlineFired,
          ))
        False -> None
      }

      let idle_timer = case deadlines.idle_timeout_ms > 0 {
        True ->
          Some(process.send_after(
            subject,
            deadlines.idle_timeout_ms,
            IdleDeadlineFired,
          ))
        False -> None
      }

      let consumer_monitor = process.monitor(consumer_pid)

      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(DownMessage)

      let initial_state =
        State(
          self_subject: subject,
          limits: limits,
          deadlines: deadlines,
          framer: sse.new(limits),
          provider: reducer,
          provider_identity: identity,
          admitted_tools: tools,
          tool_call_checks: checks,
          queue: [],
          queue_count: 0,
          queue_bytes: 0,
          pending_read: None,
          transport: transport,
          transport_closed: False,
          overall_timer: overall_timer,
          idle_timer: idle_timer,
          terminal_outcome: None,
          terminal_delivered: False,
          response_bytes_observed: False,
          response_bytes_received: 0,
          semantic_progress_observed: False,
          first_progress_observed: False,
          progress_text_bytes: 0,
          progress_blocks: [],
          outstanding_read_credit: True,
          consumer_monitor: consumer_monitor,
        )

      actor.initialised(initial_state)
      |> actor.selecting(selector)
      |> actor.returning(subject)
      |> Ok
    })
    |> actor.on_message(handle_message)

  case actor.start(builder) {
    Ok(started) -> {
      // Request initial bytes from transport
      transport.request_more()
      Ok(Stream(started.data))
    }
    Error(_) -> Error(types.ConfigurationError("Failed to start stream actor"))
  }
}

pub fn next(
  stream: Stream,
  timeout_ms: Int,
) -> Result(stream_types.ReadResult, types.ReadError) {
  let Stream(subject) = stream
  case is_alive(stream) {
    False -> Error(types.StreamClosed)
    True -> {
      let reply_to = process.new_subject()
      let read_id = reference.new()
      process.send(
        subject,
        Next(read_id: read_id, reply_to: reply_to, consumer_pid: process.self()),
      )

      case process.receive(reply_to, timeout_ms) {
        Ok(res) -> res
        Error(Nil) -> {
          let cancelled = process.new_subject()
          process.send(
            subject,
            CancelPendingRead(read_id: read_id, reply_to: cancelled),
          )
          case process.receive(cancelled, 5000) {
            Ok(CancelWon) -> Error(types.ReadTimeout)
            Ok(DeliveryWon) ->
              case process.receive(reply_to, 0) {
                Ok(res) -> res
                Error(Nil) -> Error(types.OwnerUnavailable)
              }
            Error(Nil) -> Error(types.OwnerUnavailable)
          }
        }
      }
    }
  }
}

pub fn close(stream: Stream) -> Result(types.CloseOutcome, types.ReadError) {
  let Stream(subject) = stream
  case is_alive(stream) {
    False -> Ok(types.AlreadyTerminal)
    True -> {
      let reply_to = process.new_subject()
      process.send(subject, Close(reply_to: reply_to))

      case process.receive(reply_to, 5000) {
        Ok(outcome) -> Ok(outcome)
        Error(Nil) -> Error(types.ReadTimeout)
      }
    }
  }
}

pub fn feed_chunk(stream: Stream, chunk: BitArray) -> Nil {
  let Stream(subject) = stream
  process.send(subject, FeedChunk(chunk))
}

pub fn feed_eof(stream: Stream) -> Nil {
  let Stream(subject) = stream
  process.send(subject, FeedEof)
}

pub fn feed_error(stream: Stream, failure: transport_failure.Failure) -> Nil {
  let Stream(subject) = stream
  process.send(subject, FeedError(failure))
}

pub fn attach_transport(stream: Stream, transport: TransportPort) -> Nil {
  let Stream(subject) = stream
  process.send(subject, AttachTransport(transport))
}

pub fn request_was_sent(stream: Stream) -> Nil {
  let Stream(subject) = stream
  process.send(subject, RequestWasSent)
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Next(read_id, reply_to, caller_pid) ->
      handle_next(state, read_id, reply_to, caller_pid)

    Close(reply_to) -> handle_close(state, reply_to)

    CancelPendingRead(read_id, reply_to) -> {
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
    }

    FeedChunk(chunk) -> handle_chunk(state, chunk)

    FeedEof -> handle_eof(state)

    FeedError(reason) -> handle_error(state, reason)

    AttachTransport(transport) -> {
      let updated_state =
        State(..state, transport: transport, outstanding_read_credit: False)
      if_needed_request_bytes(updated_state)
    }

    RequestWasSent -> {
      let _ =
        telemetry.observe(
          telemetry.RequestSent,
          provider_name(state.provider_identity),
          "gun_stream_started",
        )
      actor.continue(state)
    }

    OverallDeadlineFired -> handle_overall_deadline(state)

    IdleDeadlineFired -> handle_idle_deadline(state)

    DownMessage(down) -> handle_down(state, down)
  }
}

fn handle_next(
  state: State,
  read_id: reference.Reference,
  reply_to: process.Subject(Result(stream_types.ReadResult, types.ReadError)),
  caller_pid: process.Pid,
) -> actor.Next(State, Message) {
  let state = case state.pending_read {
    Some(pending) if pending.consumer_pid == caller_pid -> {
      process.demonitor_process(pending.monitor)
      State(..state, pending_read: None)
    }
    _ -> state
  }

  // If another read is already waiting, immediately return ConcurrentReadConflict!
  case state.pending_read {
    Some(_) -> {
      process.send(reply_to, Error(types.ConcurrentReadConflict))
      actor.continue(state)
    }
    None -> {
      // If terminal was already delivered, stream is closed
      case state.terminal_delivered {
        True -> {
          process.send(reply_to, Error(types.StreamClosed))
          let _ = perform_cleanup(state)
          actor.stop()
        }
        False -> {
          case state.queue {
            [head, ..tail] -> {
              let item_size = size_of_result(head)
              let updated_count = state.queue_count - 1
              let updated_bytes = state.queue_bytes - item_size

              let was_terminal = case head {
                stream_types.StreamTerminal(_) -> True
                stream_types.NextProgress(_) -> False
              }

              process.send(reply_to, Ok(head))

              let updated_state =
                State(
                  ..state,
                  queue: tail,
                  queue_count: updated_count,
                  queue_bytes: updated_bytes,
                  terminal_delivered: was_terminal,
                )

              case was_terminal {
                True -> {
                  let _ = perform_cleanup(updated_state)
                  actor.stop()
                }
                False -> if_needed_request_bytes(updated_state)
              }
            }
            [] -> {
              case state.terminal_outcome {
                Some(term) -> {
                  process.send(reply_to, Ok(stream_types.StreamTerminal(term)))
                  let _ = perform_cleanup(state)
                  actor.stop()
                }
                None -> {
                  // Wait for transport input: monitor consumer and park request
                  let monitor = process.monitor(caller_pid)
                  let pending =
                    PendingRead(read_id, reply_to, caller_pid, monitor)
                  let updated_state =
                    State(..state, pending_read: Some(pending))
                  if_needed_request_bytes(updated_state)
                }
              }
            }
          }
        }
      }
    }
  }
}

fn handle_close(
  state: State,
  reply_to: process.Subject(types.CloseOutcome),
) -> actor.Next(State, Message) {
  case state.terminal_outcome {
    Some(_) -> {
      process.send(reply_to, types.AlreadyTerminal)
      let _ = perform_cleanup(state)
      actor.stop()
    }
    None -> {
      let cleaned = perform_cleanup(state)
      let _ =
        telemetry.observe(
          telemetry.Cancelled,
          provider_name(cleaned.provider_identity),
          "consumer_closed",
        )
      let retry_evidence =
        get_retry_evidence(
          cleaned.provider,
          types.RequestMayHaveReachedProvider,
          cleaned.response_bytes_observed,
          cleaned.semantic_progress_observed,
        )
      let outcome = stream_types.StreamCancelledLocally(retry_evidence)

      // If a consumer read was pending, reply to it
      case cleaned.pending_read {
        Some(pending) -> {
          process.demonitor_process(pending.monitor)
          process.send(pending.caller, Ok(stream_types.StreamTerminal(outcome)))
        }
        None -> Nil
      }

      process.send(reply_to, types.ConsumerClosed)
      let _ = perform_cleanup(cleaned)
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
            types.ResourceLimitExceeded(
              "response_body_bytes_limit",
              state.limits.response_body_bytes_limit,
              received,
            ),
          )
        False ->
          case sse.feed(with_bytes.framer, chunk) {
            Error(err) -> fail_stream(with_bytes, err)
            Ok(#(next_framer, sse_events)) -> {
              let state_with_framer = State(..with_bytes, framer: next_framer)
              process_sse_events(state_with_framer, sse_events)
            }
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
      case step_provider(state.provider, event) {
        Error(err) -> fail_stream(state, err)
        Ok(#(next_provider, progress_list)) -> {
          let state_with_provider = State(..state, provider: next_provider)
          case ingest_progress(state_with_provider, progress_list) {
            Error(#(partial_state, err)) -> fail_stream(partial_state, err)
            Ok(after_progress_state) -> {
              case terminal_provider(after_progress_state) {
                Ok(Some(terminal)) -> {
                  let cleaned = perform_cleanup(after_progress_state)
                  let final_state =
                    State(..cleaned, terminal_outcome: Some(terminal))
                  deliver_or_enqueue(
                    final_state,
                    stream_types.StreamTerminal(terminal),
                  )
                }
                Ok(None) -> process_sse_events(after_progress_state, rest)
                Error(error) -> fail_stream(after_progress_state, error)
              }
            }
          }
        }
      }
    }
  }
}

fn ingest_progress(
  state: State,
  progress_list: List(types.StreamProgress),
) -> Result(State, #(State, types.WireError)) {
  list.fold(progress_list, Ok(state), fn(acc, progress) {
    case acc {
      Error(e) -> Error(e)
      Ok(curr_state) -> {
        case validate_progress(curr_state, progress) {
          Error(error) -> Error(#(curr_state, error))
          Ok(validated) -> {
            let size = size_of_progress(progress)
            case
              validated.queue_count + 1 > validated.limits.queue_count_limit
            {
              True ->
                Error(#(
                  curr_state,
                  types.ResourceLimitExceeded(
                    "queue_count_limit",
                    validated.limits.queue_count_limit,
                    validated.queue_count + 1,
                  ),
                ))
              False ->
                case
                  validated.queue_bytes + size
                  > validated.limits.queue_bytes_limit
                {
                  True ->
                    Error(#(
                      curr_state,
                      types.ResourceLimitExceeded(
                        "queue_bytes_limit",
                        validated.limits.queue_bytes_limit,
                        validated.queue_bytes + size,
                      ),
                    ))
                  False -> {
                    let reset_state = case is_semantic_progress(progress) {
                      True ->
                        restart_idle_timer(
                          State(..validated, semantic_progress_observed: True),
                        )
                      False -> validated
                    }
                    let progress_state = case
                      reset_state.first_progress_observed
                    {
                      True -> reset_state
                      False -> {
                        let _ =
                          telemetry.observe(
                            telemetry.FirstProgress,
                            provider_name(reset_state.provider_identity),
                            "received",
                          )
                        State(..reset_state, first_progress_observed: True)
                      }
                    }
                    Ok(dispatch_or_queue_progress(
                      progress_state,
                      progress,
                      size,
                    ))
                  }
                }
            }
          }
        }
      }
    }
  })
}

fn validate_progress(
  state: State,
  progress: types.StreamProgress,
) -> Result(State, types.WireError) {
  case progress {
    types.TextDelta(block_id, text) ->
      add_progress_text(state, "text:" <> block_id, text)
    types.RefusalDelta(block_id, text) ->
      add_progress_text(state, "refusal:" <> block_id, text)
    types.ReasoningDelta(block_id, text) ->
      add_progress_text(state, "reasoning:" <> block_id, text)
    types.UsageUpdate(_) -> Ok(state)
    types.ProviderExtension(provider_name, event_name) -> {
      let bytes = string.byte_size(provider_name) + string.byte_size(event_name)
      case bytes > state.limits.extension_bytes_limit {
        True ->
          Error(types.ResourceLimitExceeded(
            "extension_bytes_limit",
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
) -> Result(State, types.WireError) {
  let delta_bytes = string.byte_size(text)
  let prior = case
    list.find(state.progress_blocks, fn(block) { block.0 == block_key })
  {
    Ok(block) -> block.1
    Error(Nil) -> 0
  }
  let block_bytes = prior + delta_bytes
  let total_bytes = state.progress_text_bytes + delta_bytes
  let is_new =
    !list.any(state.progress_blocks, fn(block) { block.0 == block_key })
  let blocks = case is_new {
    True -> [#(block_key, block_bytes), ..state.progress_blocks]
    False ->
      list.map(state.progress_blocks, fn(block) {
        case block.0 == block_key {
          True -> #(block_key, block_bytes)
          False -> block
        }
      })
  }
  case
    block_bytes > state.limits.text_bytes_per_block_limit,
    total_bytes > state.limits.total_text_bytes_limit,
    list.length(blocks) > state.limits.active_blocks_limit
  {
    True, _, _ ->
      Error(types.ResourceLimitExceeded(
        "text_bytes_per_block_limit",
        state.limits.text_bytes_per_block_limit,
        block_bytes,
      ))
    _, True, _ ->
      Error(types.ResourceLimitExceeded(
        "total_text_bytes_limit",
        state.limits.total_text_bytes_limit,
        total_bytes,
      ))
    _, _, True ->
      Error(types.ResourceLimitExceeded(
        "active_blocks_limit",
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
  progress: types.StreamProgress,
  size: Int,
) -> State {
  case state.pending_read {
    Some(pending) if state.queue == [] -> {
      process.demonitor_process(pending.monitor)
      process.send(pending.caller, Ok(stream_types.NextProgress(progress)))
      State(..state, pending_read: None)
    }
    _ -> {
      State(
        ..state,
        queue: list.append(state.queue, [stream_types.NextProgress(progress)]),
        queue_count: state.queue_count + 1,
        queue_bytes: state.queue_bytes + size,
      )
    }
  }
}

fn deliver_or_enqueue(
  state: State,
  result: stream_types.ReadResult,
) -> actor.Next(State, Message) {
  case result {
    stream_types.StreamTerminal(terminal) -> {
      let _ =
        telemetry.observe(
          telemetry.Terminal,
          provider_name(state.provider_identity),
          terminal_name(terminal),
        )
      case state.pending_read {
        Some(pending) if state.queue == [] -> {
          process.demonitor_process(pending.monitor)
          process.send(pending.caller, Ok(result))
          let _ = perform_cleanup(state)
          actor.stop()
        }
        // Keep the terminal in its dedicated state slot. The progress queue
        // remains within its declared count and byte bounds.
        _ -> actor.continue(State(..state, terminal_outcome: Some(terminal)))
      }
    }
    stream_types.NextProgress(_) ->
      case state.pending_read {
        Some(pending) if state.queue == [] -> {
          process.demonitor_process(pending.monitor)
          process.send(pending.caller, Ok(result))
          actor.continue(
            State(..state, pending_read: None, terminal_delivered: False),
          )
        }
        _ -> {
          let item_size = size_of_result(result)
          actor.continue(
            State(
              ..state,
              queue: list.append(state.queue, [result]),
              queue_count: state.queue_count + 1,
              queue_bytes: state.queue_bytes + item_size,
            ),
          )
        }
      }
  }
}

fn fail_stream(
  state: State,
  error: types.WireError,
) -> actor.Next(State, Message) {
  let cleaned = perform_cleanup(state)
  let retry_evidence =
    get_retry_evidence(
      state.provider,
      types.RequestMayHaveReachedProvider,
      cleaned.response_bytes_observed,
      cleaned.semantic_progress_observed,
    )
  let outcome = stream_types.StreamFailed(error, retry_evidence)
  let final_state = State(..cleaned, terminal_outcome: Some(outcome))
  deliver_or_enqueue(final_state, stream_types.StreamTerminal(outcome))
}

fn handle_eof(state: State) -> actor.Next(State, Message) {
  case state.terminal_outcome {
    Some(_) -> actor.continue(state)
    None -> {
      case sse.finish(state.framer) {
        Error(err) -> fail_stream(state, err)
        Ok(_) -> {
          case terminal_provider(state) {
            Ok(Some(outcome)) -> {
              let cleaned = perform_cleanup(state)
              let final_state =
                State(..cleaned, terminal_outcome: Some(outcome))
              deliver_or_enqueue(
                final_state,
                stream_types.StreamTerminal(outcome),
              )
            }
            Ok(None) ->
              fail_stream(
                state,
                types.ProtocolError("Unexpected EOF before stream completed"),
              )
            Error(error) -> fail_stream(state, error)
          }
        }
      }
    }
  }
}

fn handle_error(
  state: State,
  failure: transport_failure.Failure,
) -> actor.Next(State, Message) {
  fail_stream(state, transport_failure.to_wire_error(failure))
}

fn handle_overall_deadline(state: State) -> actor.Next(State, Message) {
  case state.terminal_outcome {
    Some(_) -> actor.continue(state)
    None -> {
      let _ =
        telemetry.observe(
          telemetry.Deadline,
          provider_name(state.provider_identity),
          "overall",
        )
      fail_stream(state, types.DeadlineExceeded(types.OverallDeadline))
    }
  }
}

fn handle_idle_deadline(state: State) -> actor.Next(State, Message) {
  case state.terminal_outcome {
    Some(_) -> actor.continue(state)
    None -> {
      let _ =
        telemetry.observe(
          telemetry.Deadline,
          provider_name(state.provider_identity),
          "idle",
        )
      fail_stream(state, types.DeadlineExceeded(types.IdleDeadline))
    }
  }
}

fn handle_down(state: State, down: process.Down) -> actor.Next(State, Message) {
  case down {
    process.ProcessDown(..) -> {
      let _cleaned = perform_cleanup(state)
      actor.stop()
    }
    _ -> actor.continue(state)
  }
}

fn restart_idle_timer(state: State) -> State {
  case state.idle_timer {
    Some(t) -> {
      process.cancel_timer(t)
      Nil
    }
    None -> Nil
  }
  case state.terminal_outcome {
    Some(_) -> state
    None -> {
      case state.deadlines.idle_timeout_ms > 0 {
        True -> {
          let timer =
            process.send_after(
              state.self_subject,
              state.deadlines.idle_timeout_ms,
              IdleDeadlineFired,
            )
          State(..state, idle_timer: Some(timer))
        }
        False -> state
      }
    }
  }
}

fn perform_cleanup(state: State) -> State {
  case state.transport_closed {
    True -> state
    False -> {
      case state.overall_timer {
        Some(t) -> {
          process.cancel_timer(t)
          Nil
        }
        None -> Nil
      }
      case state.idle_timer {
        Some(t) -> {
          process.cancel_timer(t)
          Nil
        }
        None -> Nil
      }
      state.transport.close()
      let _ =
        telemetry.observe(
          telemetry.Cleanup,
          provider_name(state.provider_identity),
          "transport_closed",
        )
      State(
        ..state,
        transport_closed: True,
        overall_timer: None,
        idle_timer: None,
      )
    }
  }
}

fn provider_name(identity: types.Provider) -> String {
  case identity {
    types.OpenAI -> "openai"
    types.Anthropic -> "anthropic"
    types.Google -> "google"
    types.Custom(name) -> name
  }
}

fn terminal_name(terminal: stream_types.TerminalOutcome) -> String {
  case terminal {
    stream_types.StreamFinished(stream_types.CompletedText(_), _) ->
      "completed_text"
    stream_types.StreamFinished(stream_types.Refused(_), _) -> "refused"
    stream_types.StreamFinished(stream_types.CompletedToolCalls(..), _) ->
      "completed_tools"
    stream_types.StreamFinished(stream_types.CompletedToolCallsWithData(..), _) ->
      "completed_tools"
    stream_types.StreamFinished(stream_types.OutputLimited(_, _), _) ->
      "output_limited"
    stream_types.StreamFailed(_, _) -> "failed"
    stream_types.StreamCancelledLocally(_) -> "cancelled"
  }
}

fn if_needed_request_bytes(state: State) -> actor.Next(State, Message) {
  case state.terminal_outcome, state.transport_closed {
    None, False -> {
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
    }
    _, _ -> actor.continue(state)
  }
}

fn get_retry_evidence(
  reducer: provider.Reducer,
  fallback: types.RetryClassification,
  response_bytes: Bool,
  semantic_progress: Bool,
) -> types.RetryEvidence {
  let reported = provider.retry_evidence(reducer, fallback)
  merge_retry_evidence(reported, fallback, response_bytes, semantic_progress)
}

fn merge_retry_evidence(
  reported: types.RetryEvidence,
  fallback: types.RetryClassification,
  response_bytes: Bool,
  semantic_progress: Bool,
) -> types.RetryEvidence {
  let classification = case reported.classification, fallback {
    types.EffectUnknown, _ | _, types.EffectUnknown -> types.EffectUnknown
    types.RequestMayHaveReachedProvider, _
    | _, types.RequestMayHaveReachedProvider
    -> types.RequestMayHaveReachedProvider
    types.NoRequestSent, types.NoRequestSent -> types.NoRequestSent
  }
  types.RetryEvidence(
    classification: classification,
    response_bytes_observed: reported.response_bytes_observed || response_bytes,
    semantic_progress_observed: reported.semantic_progress_observed
      || semantic_progress,
  )
}

fn step_provider(
  reducer: provider.Reducer,
  event: sse.ServerSentEvent,
) -> Result(#(provider.Reducer, List(types.StreamProgress)), types.WireError) {
  provider.step(
    reducer,
    provider.Event(event.event, event.data, event.id, event.retry),
  )
}

fn terminal_provider(
  state: State,
) -> Result(Option(stream_types.TerminalOutcome), types.WireError) {
  case provider.terminal(state.provider) {
    None -> Ok(None)
    Some(provider.Text(text, usage)) ->
      result.map(call_admission.validate_text(state.limits, text), fn(_) {
        Some(stream_types.StreamFinished(
          stream_types.CompletedText(text),
          usage,
        ))
      })
    Some(provider.ToolCalls(text, calls, response_id, provider_data, usage)) -> {
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
    Some(provider.OutputLimited(text, calls, usage)) -> {
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
    Some(provider.Refusal(reason, usage)) ->
      result.map(call_admission.validate_text(state.limits, reason), fn(_) {
        Some(stream_types.StreamFinished(stream_types.Refused(reason), usage))
      })
    Some(provider.Failure(error, retry)) ->
      Ok(
        Some(stream_types.StreamFailed(
          error,
          merge_retry_evidence(
            retry,
            types.RequestMayHaveReachedProvider,
            state.response_bytes_observed,
            state.semantic_progress_observed,
          ),
        )),
      )
    Some(provider.Cancellation(retry)) ->
      Ok(
        Some(
          stream_types.StreamCancelledLocally(merge_retry_evidence(
            retry,
            types.RequestMayHaveReachedProvider,
            state.response_bytes_observed,
            state.semantic_progress_observed,
          )),
        ),
      )
  }
}

fn validate_partial_calls(
  limits: types.Limits,
  calls: List(types.ToolCall),
) -> Result(Nil, types.WireError) {
  let count = list.length(calls)
  use Nil <- result.try(case count > limits.active_blocks_limit {
    True ->
      Error(types.ResourceLimitExceeded(
        "active_blocks_limit",
        limits.active_blocks_limit,
        count,
      ))
    False -> Ok(Nil)
  })
  use _ <- result.try(
    list.fold(calls, Ok(0), fn(acc, call) {
      use prior <- result.try(acc)
      let bytes = string.byte_size(call.arguments_json)
      use Nil <- result.try(case bytes > limits.argument_bytes_per_call_limit {
        True ->
          Error(types.ResourceLimitExceeded(
            "argument_bytes_per_call_limit",
            limits.argument_bytes_per_call_limit,
            bytes,
          ))
        False -> Ok(Nil)
      })
      let total = prior + bytes
      case total > limits.total_argument_bytes_limit {
        True ->
          Error(types.ResourceLimitExceeded(
            "total_argument_bytes_limit",
            limits.total_argument_bytes_limit,
            total,
          ))
        False -> Ok(total)
      }
    }),
  )
  Ok(Nil)
}

fn is_semantic_progress(progress: types.StreamProgress) -> Bool {
  case progress {
    types.TextDelta(_, _) -> True
    types.RefusalDelta(_, _) -> True
    types.ReasoningDelta(_, _) -> True
    types.UsageUpdate(_) -> True
    types.ProviderExtension(_, _) -> False
  }
}

fn size_of_result(result: stream_types.ReadResult) -> Int {
  case result {
    stream_types.NextProgress(p) -> size_of_progress(p)
    stream_types.StreamTerminal(_) -> 64
  }
}

fn size_of_progress(progress: types.StreamProgress) -> Int {
  case progress {
    types.TextDelta(id, t) -> string.byte_size(id) + string.byte_size(t) + 32
    types.RefusalDelta(id, t) -> string.byte_size(id) + string.byte_size(t) + 32
    types.ReasoningDelta(id, t) ->
      string.byte_size(id) + string.byte_size(t) + 32
    types.UsageUpdate(_) -> 24
    types.ProviderExtension(provider_name, e) ->
      string.byte_size(provider_name) + string.byte_size(e) + 16
  }
}
