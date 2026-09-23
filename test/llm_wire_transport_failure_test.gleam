import gleeunit/should
import llm_wire/internal/transport_failure
import llm_wire/types

pub fn gun_deadline_race_keeps_deadline_classification_test() {
  transport_failure.to_wire_error(transport_failure.OverallDeadlineFailure)
  |> should.equal(types.DeadlineExceeded(types.OverallDeadline))
}

pub fn other_gun_failure_keeps_transport_classification_test() {
  transport_failure.to_wire_error(transport_failure.TransportFailure(
    "overall deadline exceeded",
  ))
  |> should.equal(types.TransportError("overall deadline exceeded"))
  transport_failure.to_wire_error(transport_failure.TransportFailure(
    "connection refused",
  ))
  |> should.equal(types.TransportError("connection refused"))
}
