//// Describes the Sinal lifecycle observations that LLM calls emit.
////
//// Each prepared and executed call emits the `[llm_wire, observation]` event
//// at fixed stages (`Stage`), with `Metadata` holding only the stage, the
//// provider name and a low-cardinality outcome. Attach a Sinal handler to
//// `observation_event()` to count or log calls. The metadata never carries
//// request or response content, or credentials.

import sinal
import sinal/fields

/// Lifecycle observations contain only a fixed stage, provider name and
/// low-cardinality outcome. They never carry request or response content.
pub type Stage {
  Prepared
  RequestSent
  FirstProgress
  Terminal
  Cancelled
  Deadline
  Cleanup
}

pub type Metadata {
  Metadata(stage: String, provider: String, outcome: String)
}

@internal
pub fn observe(stage: Stage, provider: String, outcome: String) -> Nil {
  sinal.emit(
    observation_event(),
    Nil,
    Metadata(stage_name(stage), provider, outcome),
  )
}

pub fn observation_event() -> sinal.Event(Nil, Metadata) {
  let metadata_fields = {
    use stage <- fields.include(fields.string("stage"), get: fn(m) { m.stage })
    use provider <- fields.include(fields.string("provider"), get: fn(m) {
      m.provider
    })
    use outcome <- fields.include(fields.string("outcome"), get: fn(m) {
      m.outcome
    })
    fields.success(Metadata(stage:, provider:, outcome:))
  }
  sinal.event(["llm_wire", "observation"], fields.empty(), metadata_fields)
}

fn stage_name(stage: Stage) -> String {
  case stage {
    Prepared -> "prepared"
    RequestSent -> "request_sent"
    FirstProgress -> "first_progress"
    Terminal -> "terminal"
    Cancelled -> "cancelled"
    Deadline -> "deadline"
    Cleanup -> "cleanup"
  }
}
