import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
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

pub fn observe(stage: Stage, provider: String, outcome: String) -> Nil {
  let observation = observation_event()
  let _ =
    sinal.emit(observation, Nil, Metadata(stage_name(stage), provider, outcome))
  Nil
}

pub fn observation_event() -> sinal.Event(Nil, Metadata) {
  let stage = string_field("stage")
  let provider = string_field("provider")
  let outcome = string_field("outcome")
  let assert Ok(first_two) = fields.pair(stage, provider)
  let assert Ok(all_fields) = fields.pair(first_two, outcome)
  let metadata_fields =
    fields.imap(
      all_fields,
      fn(values) { Metadata(values.0.0, values.0.1, values.1) },
      fn(value) { #(#(value.stage, value.provider), value.outcome) },
    )
  let assert Ok(event) =
    sinal.event(
      [atom.create("llm_wire"), atom.create("observation")],
      fields.empty(),
      metadata_fields,
    )
  event
}

fn string_field(name: String) -> fields.Fields(String) {
  fields.field(
    atom.create(name),
    fn(value) { Ok(dynamic.string(value)) },
    fn(raw) {
      case decode.run(raw, decode.string) {
        Ok(value) -> Ok(value)
        Error(_) -> Error(fields.FieldDecodeError("expected string metadata"))
      }
    },
  )
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
