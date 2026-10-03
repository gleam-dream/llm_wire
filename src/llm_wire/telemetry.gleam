//// Describes the Sinal events that every executed LLM call emits.
////
//// Each execution of a prepared call emits `[llm_wire, observation]` at
//// fixed stages. Its `Metadata` names the call, the caller's correlation,
//// the stage, the provider and a low-cardinality outcome. It never carries
//// request or response content, or credentials.
////
//// ```gleam
//// import llm_wire/telemetry
//// import sinal
////
//// sinal.observe(telemetry.event(), fn(_, meta) {
////   log(meta.call, telemetry.stage_name(meta.stage), meta.provider)
//// })
//// ```
////
//// `call` is minted for every execution, so the events of one `run` or
//// `stream` share it and a retry gets a new one. `correlation` is the
//// correlation of the `http_gun.Client` view the call ran on, the value
//// HTTP Gun also carries for the HTTP request under the same key, so both
//// packages' events join.

import gleam/option.{type Option}
import sinal
import sinal/correlation.{type Correlation}
import sinal/fields

/// The point in a call's life an event marks.
pub type Stage {
  /// Execution began.
  Started
  /// The provider's response head arrived.
  RequestSent
  /// The first progress event arrived.
  FirstProgress
  /// The call reached its final outcome.
  Terminal
  /// The caller closed the stream before the end.
  Cancelled
  /// A timer expired.
  Deadline
  /// The HTTP stream was released.
  Cleanup
}

/// What happened at the stage.
pub type Outcome {
  Accepted
  ResponseStarted
  Received
  Answered
  ToolsRequested
  Refused
  OutputLimited
  Failed
  CallCancelled
  ConsumerClosed
  WholeCallExpired
  FirstTokenExpired
  IdleGapExpired
  TransportClosed
}

/// Read fields by label; it may gain fields.
pub type Metadata {
  Metadata(
    call: String,
    correlation: Option(Correlation),
    stage: Stage,
    provider: String,
    outcome: Outcome,
  )
}

/// The `[llm_wire, observation]` event.
pub fn event() -> sinal.Event(Nil, Metadata) {
  let metadata_fields = {
    use call <- fields.include(fields.string("call"), get: fn(m: Metadata) {
      m.call
    })
    use correlation <- fields.include(correlation.field(), get: fn(m) {
      m.correlation
    })
    use stage <- fields.include(
      fields.enum("stage", all_stages(), stage_name),
      get: fn(m) { m.stage },
    )
    use provider <- fields.include(fields.string("provider"), get: fn(m) {
      m.provider
    })
    use outcome <- fields.include(
      fields.enum("outcome", all_outcomes(), outcome_name),
      get: fn(m) { m.outcome },
    )
    fields.success(Metadata(call:, correlation:, stage:, provider:, outcome:))
  }
  sinal.event(["llm_wire", "observation"], fields.empty(), metadata_fields)
}

/// A stable snake_case name, such as `"first_progress"`.
pub fn stage_name(stage: Stage) -> String {
  case stage {
    Started -> "started"
    RequestSent -> "request_sent"
    FirstProgress -> "first_progress"
    Terminal -> "terminal"
    Cancelled -> "cancelled"
    Deadline -> "deadline"
    Cleanup -> "cleanup"
  }
}

/// A stable snake_case name, such as `"completed_tools"`.
pub fn outcome_name(outcome: Outcome) -> String {
  case outcome {
    Accepted -> "accepted"
    ResponseStarted -> "http_response_started"
    Received -> "received"
    Answered -> "completed_text"
    ToolsRequested -> "completed_tools"
    Refused -> "refused"
    OutputLimited -> "output_limited"
    Failed -> "failed"
    CallCancelled -> "cancelled"
    ConsumerClosed -> "consumer_closed"
    WholeCallExpired -> "whole_call"
    FirstTokenExpired -> "first_token"
    IdleGapExpired -> "idle_gap"
    TransportClosed -> "transport_closed"
  }
}

fn all_stages() -> List(Stage) {
  [Started, RequestSent, FirstProgress, Terminal, Cancelled, Deadline, Cleanup]
}

fn all_outcomes() -> List(Outcome) {
  [
    Accepted,
    ResponseStarted,
    Received,
    Answered,
    ToolsRequested,
    Refused,
    OutputLimited,
    Failed,
    CallCancelled,
    ConsumerClosed,
    WholeCallExpired,
    FirstTokenExpired,
    IdleGapExpired,
    TransportClosed,
  ]
}
