import gleeunit/should
import http_gun/error
import llm_wire/internal/http_client
import llm_wire/types

pub fn http_deadline_keeps_deadline_classification_test() {
  http_client.wire_error(error.new(error.DeadlineExceeded, error.MaybeSent))
  |> should.equal(types.DeadlineExceeded(types.OverallDeadline))
}

pub fn diagnostic_text_does_not_determine_failure_category_test() {
  // Another timeout is not the call's overall deadline.
  http_client.wire_error(error.new(error.IdleTimeout, error.NotSent))
  |> should.equal(types.HttpFailure(error.IdleTimeout))
  http_client.wire_error(error.new(
    error.ConnectionFailed(error.ConnectionRefused),
    error.NotSent,
  ))
  |> should.equal(
    types.HttpFailure(error.ConnectionFailed(error.ConnectionRefused)),
  )
}
