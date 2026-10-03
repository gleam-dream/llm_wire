import gleam/option.{type Option}
import llm_wire/error.{type Error}
import llm_wire/message.{type Progress, type ToolCall, type Usage}
import llm_wire/tool.{type ToolCallIssue}

/// Reducer outcomes, converted to public outcomes at the facade.
pub type Outcome {
  CompletedText(text: String)
  Refused(reason: String)
  /// `issues` is filled only by the runtime's terminal admission; a reducer
  /// reports none.
  CompletedToolCalls(
    text: String,
    calls: List(ToolCall),
    response_id: Option(String),
    issues: List(ToolCallIssue),
  )
  CompletedToolCallsWithData(
    text: String,
    calls: List(ToolCall),
    response_id: Option(String),
    provider_data: String,
    issues: List(ToolCallIssue),
  )
  OutputLimited(partial_text: String, partial_calls: List(ToolCall))
}

/// What the runtime observed about delivery when a call ended.
pub type RetryClassification {
  NoRequestSent
  RequestMayHaveReachedProvider
  EffectUnknown
  /// The provider finished its response, with an error or invalid content.
  ResponseCompleted
}

pub type RetryEvidence {
  RetryEvidence(
    classification: RetryClassification,
    response_bytes_observed: Bool,
    semantic_progress_observed: Bool,
  )
}

pub fn initial_retry_evidence() -> RetryEvidence {
  RetryEvidence(NoRequestSent, False, False)
}

pub type TerminalOutcome {
  StreamFinished(outcome: Outcome, usage: Option(Usage))
  StreamFailed(error: Error, retry: RetryEvidence)
  StreamCancelledLocally(retry: RetryEvidence)
}

pub type ReadResult {
  NextProgress(Progress)
  /// `usage` is the last usage the stream reported, kept for failures.
  StreamTerminal(TerminalOutcome, usage: Option(Usage))
}

pub type ReadError {
  StreamClosed
  ConcurrentReadConflict
  OwnerUnavailable
  ReadTimeout
}

pub type CloseOutcome {
  ConsumerClosed
  AlreadyTerminal
}
