import gleam/list
import gleeunit/should
import llm_wire/internal/transport_failure
import llm_wire/types

pub fn gun_deadline_race_keeps_deadline_classification_test() {
  [
    "overall deadline exceeded",
    "overall deadline exceeded during setup",
    "overall deadline exceeded waiting for headers",
    "overall deadline exceeded reading error response",
  ]
  |> list.each(fn(reason) {
    transport_failure.classify(reason)
    |> should.equal(types.DeadlineExceeded(types.OverallDeadline))
  })
}

pub fn other_gun_failure_keeps_transport_classification_test() {
  transport_failure.classify("connection refused")
  |> should.equal(types.TransportError("connection refused"))
}
