import llm_wire/types

/// Gun and the stream owner enforce the same overall deadline. Classify Gun's
/// timeout first so their delivery order cannot change the public outcome.
pub fn classify(reason: String) -> types.WireError {
  case reason {
    "overall deadline exceeded"
    | "overall deadline exceeded during setup"
    | "overall deadline exceeded waiting for headers"
    | "overall deadline exceeded reading error response" ->
      types.DeadlineExceeded(types.OverallDeadline)
    _ -> types.TransportError(reason)
  }
}
