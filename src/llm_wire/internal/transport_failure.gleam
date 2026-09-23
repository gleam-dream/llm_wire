import llm_wire/types

/// The Erlang transport reports categories, not diagnostic phrases.
pub type Failure {
  TransportFailure(reason: String)
  OverallDeadlineFailure
}

pub fn to_wire_error(failure: Failure) -> types.WireError {
  case failure {
    TransportFailure(reason) -> types.TransportError(reason)
    OverallDeadlineFailure -> types.DeadlineExceeded(types.OverallDeadline)
  }
}
