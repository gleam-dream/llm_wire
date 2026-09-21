import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import llm_wire/anthropic
import llm_wire/openai
import llm_wire/sse
import llm_wire/types

pub opaque type Stream {
  Stream(subject: process.Subject(Message))
}

pub type TransportPort {
  TransportPort(request_more: fn() -> Nil, close: fn() -> Nil)
}

pub type ProviderAdapter {
  OpenAIAdapter(openai.Reducer)
  AnthropicAdapter(anthropic.Reducer)
}

pub type Message {
  Next(
    reply_to: process.Subject(Result(types.ReadResult, types.ReadError)),
    consumer_pid: process.Pid,
  )
  Close(reply_to: process.Subject(types.CloseOutcome))
  FeedChunk(chunk: BitArray)
  FeedEof
  FeedError(reason: String)
  AttachTransport(transport: TransportPort)
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
    provider: ProviderAdapter,
    queue: List(types.ReadResult),
    queue_count: Int,
    queue_bytes: Int,
    pending_read: Option(PendingRead),
    transport: TransportPort,
    transport_closed: Bool,
    overall_timer: Option(process.Timer),
    idle_timer: Option(process.Timer),
    terminal_outcome: Option(types.TerminalOutcome),
    terminal_delivered: Bool,
    response_bytes_observed: Bool,
    semantic_progress_observed: Bool,
  )
}

type PendingRead {
  PendingRead(
    caller: process.Subject(Result(types.ReadResult, types.ReadError)),
    consumer_pid: process.Pid,
    monitor: process.Monitor,
  )
}

pub fn start_openai_stream(
  limits: types.Limits,
  deadlines: types.Deadlines,
  transport: TransportPort,
) -> Result(Stream, types.WireError) {
  start_stream(OpenAIAdapter(openai.new(limits)), limits, deadlines, transport)
}

pub fn start_anthropic_stream(
  limits: types.Limits,
  deadlines: types.Deadlines,
  transport: TransportPort,
) -> Result(Stream, types.WireError) {
  start_stream(
    AnthropicAdapter(anthropic.new(limits)),
    limits,
    deadlines,
    transport,
  )
}

fn start_stream(
  provider: ProviderAdapter,
  limits: types.Limits,
  deadlines: types.Deadlines,
  transport: TransportPort,
) -> Result(Stream, types.WireError) {
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
          provider: provider,
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
          semantic_progress_observed: False,
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
) -> Result(types.ReadResult, types.ReadError) {
  let Stream(subject) = stream
  let reply_to = process.new_subject()
  process.send(subject, Next(reply_to: reply_to, consumer_pid: process.self()))

  case process.receive(reply_to, timeout_ms) {
    Ok(res) -> res
    Error(Nil) -> Error(types.ReadTimeout)
  }
}

pub fn close(stream: Stream) -> Result(types.CloseOutcome, types.ReadError) {
  let Stream(subject) = stream
  let reply_to = process.new_subject()
  process.send(subject, Close(reply_to: reply_to))

  case process.receive(reply_to, 5000) {
    Ok(outcome) -> Ok(outcome)
    Error(Nil) -> Error(types.ReadTimeout)
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

pub fn feed_error(stream: Stream, reason: String) -> Nil {
  let Stream(subject) = stream
  process.send(subject, FeedError(reason))
}

pub fn attach_transport(stream: Stream, transport: TransportPort) -> Nil {
  let Stream(subject) = stream
  process.send(subject, AttachTransport(transport))
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Next(reply_to, caller_pid) -> handle_next(state, reply_to, caller_pid)

    Close(reply_to) -> handle_close(state, reply_to)

    FeedChunk(chunk) -> handle_chunk(state, chunk)

    FeedEof -> handle_eof(state)

    FeedError(reason) -> handle_error(state, reason)

    AttachTransport(transport) -> {
      let updated_state = State(..state, transport: transport)
      if_needed_request_bytes(updated_state)
    }

    OverallDeadlineFired -> handle_overall_deadline(state)

    IdleDeadlineFired -> handle_idle_deadline(state)

    DownMessage(down) -> handle_down(state, down)
  }
}

fn handle_next(
  state: State,
  reply_to: process.Subject(Result(types.ReadResult, types.ReadError)),
  caller_pid: process.Pid,
) -> actor.Next(State, Message) {
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
          actor.continue(state)
        }
        False -> {
          case state.queue {
            [head, ..tail] -> {
              let item_size = size_of_result(head)
              let updated_count = state.queue_count - 1
              let updated_bytes = state.queue_bytes - item_size

              let was_terminal = case head {
                types.StreamTerminal(_) -> True
                types.NextProgress(_) -> False
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

              // If queue is now below high-water mark, request more bytes from transport
              if_needed_request_bytes(updated_state)
            }
            [] -> {
              case state.terminal_outcome {
                Some(term) -> {
                  process.send(reply_to, Ok(types.StreamTerminal(term)))
                  actor.continue(State(..state, terminal_delivered: True))
                }
                None -> {
                  // Wait for transport input: monitor consumer and park request
                  let monitor = process.monitor(caller_pid)
                  let pending = PendingRead(reply_to, caller_pid, monitor)
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
      actor.continue(state)
    }
    None -> {
      let cleaned = perform_cleanup(state)
      let retry_evidence =
        types.RetryEvidence(
          classification: types.RequestMayHaveReachedProvider,
          response_bytes_observed: cleaned.response_bytes_observed,
          semantic_progress_observed: cleaned.semantic_progress_observed,
        )
      let outcome = types.StreamCancelledLocally(retry_evidence)

      // If a consumer read was pending, reply to it
      case cleaned.pending_read {
        Some(pending) -> {
          process.demonitor_process(pending.monitor)
          process.send(pending.caller, Ok(types.StreamTerminal(outcome)))
        }
        None -> Nil
      }

      process.send(reply_to, types.ConsumerClosed)
      actor.continue(
        State(
          ..cleaned,
          pending_read: None,
          terminal_outcome: Some(outcome),
          terminal_delivered: True,
        ),
      )
    }
  }
}

fn handle_chunk(state: State, chunk: BitArray) -> actor.Next(State, Message) {
  case state.terminal_outcome {
    Some(_) -> actor.continue(state)
    None -> {
      let with_bytes = State(..state, response_bytes_observed: True)
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
            Error(err) -> fail_stream(state_with_provider, err)
            Ok(after_progress_state) -> {
              case terminal_provider(after_progress_state.provider) {
                Some(terminal) -> {
                  let cleaned = perform_cleanup(after_progress_state)
                  let final_state =
                    State(..cleaned, terminal_outcome: Some(terminal))
                  deliver_or_enqueue(
                    final_state,
                    types.StreamTerminal(terminal),
                  )
                }
                None -> process_sse_events(after_progress_state, rest)
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
) -> Result(State, types.WireError) {
  list.fold(progress_list, Ok(state), fn(acc, progress) {
    case acc {
      Error(e) -> Error(e)
      Ok(curr_state) -> {
        let size = size_of_progress(progress)
        case curr_state.queue_count + 1 > curr_state.limits.queue_count_limit {
          True ->
            Error(types.ResourceLimitExceeded(
              "queue_count_limit",
              curr_state.limits.queue_count_limit,
              curr_state.queue_count + 1,
            ))
          False ->
            case
              curr_state.queue_bytes + size
              > curr_state.limits.queue_bytes_limit
            {
              True ->
                Error(types.ResourceLimitExceeded(
                  "queue_bytes_limit",
                  curr_state.limits.queue_bytes_limit,
                  curr_state.queue_bytes + size,
                ))
              False -> {
                let reset_state = case is_semantic_progress(progress) {
                  True ->
                    restart_idle_timer(
                      State(..curr_state, semantic_progress_observed: True),
                    )
                  False -> curr_state
                }
                Ok(dispatch_or_queue_progress(reset_state, progress, size))
              }
            }
        }
      }
    }
  })
}

fn dispatch_or_queue_progress(
  state: State,
  progress: types.StreamProgress,
  size: Int,
) -> State {
  case state.pending_read {
    Some(pending) if state.queue == [] -> {
      process.demonitor_process(pending.monitor)
      process.send(pending.caller, Ok(types.NextProgress(progress)))
      State(..state, pending_read: None)
    }
    _ -> {
      State(
        ..state,
        queue: list.append(state.queue, [types.NextProgress(progress)]),
        queue_count: state.queue_count + 1,
        queue_bytes: state.queue_bytes + size,
      )
    }
  }
}

fn deliver_or_enqueue(
  state: State,
  result: types.ReadResult,
) -> actor.Next(State, Message) {
  case state.pending_read {
    Some(pending) if state.queue == [] -> {
      process.demonitor_process(pending.monitor)
      process.send(pending.caller, Ok(result))
      actor.continue(
        State(
          ..state,
          pending_read: None,
          terminal_delivered: is_terminal(result),
        ),
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

fn fail_stream(
  state: State,
  error: types.WireError,
) -> actor.Next(State, Message) {
  let cleaned = perform_cleanup(state)
  let retry_evidence =
    types.RetryEvidence(
      classification: types.RequestMayHaveReachedProvider,
      response_bytes_observed: cleaned.response_bytes_observed,
      semantic_progress_observed: cleaned.semantic_progress_observed,
    )
  let outcome = types.StreamFailed(error, retry_evidence)
  let final_state = State(..cleaned, terminal_outcome: Some(outcome))
  deliver_or_enqueue(final_state, types.StreamTerminal(outcome))
}

fn handle_eof(state: State) -> actor.Next(State, Message) {
  case state.terminal_outcome {
    Some(_) -> actor.continue(state)
    None -> {
      case sse.finish(state.framer) {
        Error(err) -> fail_stream(state, err)
        Ok(_) -> {
          case terminal_provider(state.provider) {
            Some(outcome) -> {
              let cleaned = perform_cleanup(state)
              let final_state =
                State(..cleaned, terminal_outcome: Some(outcome))
              deliver_or_enqueue(final_state, types.StreamTerminal(outcome))
            }
            None ->
              fail_stream(
                state,
                types.ProtocolError("Unexpected EOF before stream completed"),
              )
          }
        }
      }
    }
  }
}

fn handle_error(state: State, reason: String) -> actor.Next(State, Message) {
  fail_stream(state, types.TransportError(reason))
}

fn handle_overall_deadline(state: State) -> actor.Next(State, Message) {
  case state.terminal_outcome {
    Some(_) -> actor.continue(state)
    None -> fail_stream(state, types.DeadlineExceeded(types.OverallDeadline))
  }
}

fn handle_idle_deadline(state: State) -> actor.Next(State, Message) {
  case state.terminal_outcome {
    Some(_) -> actor.continue(state)
    None -> fail_stream(state, types.DeadlineExceeded(types.IdleDeadline))
  }
}

fn handle_down(state: State, down: process.Down) -> actor.Next(State, Message) {
  case down {
    process.ProcessDown(pid: pid, ..) -> {
      case state.pending_read {
        Some(pending) if pending.consumer_pid == pid -> {
          let _cleaned = perform_cleanup(state)
          actor.stop()
        }
        _ -> actor.continue(state)
      }
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
      State(
        ..state,
        transport_closed: True,
        overall_timer: None,
        idle_timer: None,
      )
    }
  }
}

fn if_needed_request_bytes(state: State) -> actor.Next(State, Message) {
  case state.terminal_outcome, state.transport_closed {
    None, False -> {
      case
        state.queue_count == 0
        || state.queue_count < state.limits.queue_count_limit / 2
      {
        True -> state.transport.request_more()
        False -> Nil
      }
      actor.continue(state)
    }
    _, _ -> actor.continue(state)
  }
}

fn step_provider(
  provider: ProviderAdapter,
  event: sse.ServerSentEvent,
) -> Result(#(ProviderAdapter, List(types.StreamProgress)), types.WireError) {
  case provider {
    OpenAIAdapter(r) -> {
      case openai.step(r, event) {
        Ok(#(nr, p)) -> Ok(#(OpenAIAdapter(nr), p))
        Error(e) -> Error(e)
      }
    }
    AnthropicAdapter(r) -> {
      case anthropic.step(r, event) {
        Ok(#(nr, p)) -> Ok(#(AnthropicAdapter(nr), p))
        Error(e) -> Error(e)
      }
    }
  }
}

fn terminal_provider(
  provider: ProviderAdapter,
) -> Option(types.TerminalOutcome) {
  case provider {
    OpenAIAdapter(r) -> openai.terminal(r)
    AnthropicAdapter(r) -> anthropic.terminal(r)
  }
}

fn is_semantic_progress(progress: types.StreamProgress) -> Bool {
  case progress {
    types.TextDelta(_, _) -> True
    types.ReasoningDelta(_, _) -> True
    types.ToolCallCompleted(_) -> True
    types.UsageUpdate(_) -> True
    types.ProviderExtension(_, _) -> False
  }
}

fn is_terminal(result: types.ReadResult) -> Bool {
  case result {
    types.StreamTerminal(_) -> True
    types.NextProgress(_) -> False
  }
}

fn size_of_result(result: types.ReadResult) -> Int {
  case result {
    types.NextProgress(p) -> size_of_progress(p)
    types.StreamTerminal(_) -> 64
  }
}

fn size_of_progress(progress: types.StreamProgress) -> Int {
  case progress {
    types.TextDelta(_, t) -> string.byte_size(t) + 32
    types.ReasoningDelta(_, t) -> string.byte_size(t) + 32
    types.ToolCallCompleted(c) -> string.byte_size(c.arguments_json) + 64
    types.UsageUpdate(_) -> 24
    types.ProviderExtension(_, e) -> string.byte_size(e) + 16
  }
}
