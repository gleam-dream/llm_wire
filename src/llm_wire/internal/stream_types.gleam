import gleam/option.{type Option}
import llm_wire/types

/// Provider-owned replay state is never accepted in an application request.
pub type ProviderContinuation {
  GoogleProviderContinuation(parts: List(String))
}

/// Reducer outcomes are converted to session results at the owned boundary.
pub type Outcome {
  CompletedText(text: String)
  Refused(reason: String)
  CompletedToolCalls(
    text: String,
    calls: List(types.ToolCall),
    response_id: Option(String),
  )
  CompletedToolCallsWithContinuation(
    text: String,
    calls: List(types.ToolCall),
    response_id: Option(String),
    provider_continuation: ProviderContinuation,
  )
  OutputLimited(partial_text: String, partial_calls: List(types.ToolCall))
}

pub type TerminalOutcome {
  StreamFinished(outcome: Outcome, usage: Option(types.Usage))
  StreamFailed(error: types.WireError, retry: types.RetryEvidence)
  StreamCancelledLocally(retry: types.RetryEvidence)
}

pub type ReadResult {
  NextProgress(types.StreamProgress)
  StreamTerminal(TerminalOutcome)
}
