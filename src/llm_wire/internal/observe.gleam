import gleam/option.{type Option}
import llm_wire/telemetry
import sinal
import sinal/correlation.{type Correlation}

/// The identity of one execution, carried by every event it emits.
pub type Context {
  Context(call: String, correlation: Option(Correlation), provider: String)
}

pub fn new_call_id() -> String {
  correlation.to_string(correlation.unique())
}

pub fn emit(
  context: Context,
  stage: telemetry.Stage,
  outcome: telemetry.Outcome,
) -> Nil {
  sinal.emit(
    telemetry.event(),
    Nil,
    telemetry.Metadata(
      call: context.call,
      correlation: context.correlation,
      stage:,
      provider: context.provider,
      outcome:,
    ),
  )
}
