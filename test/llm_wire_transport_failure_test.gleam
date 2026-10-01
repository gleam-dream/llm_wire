import gleeunit/should
import http_gun/error
import llm_wire/internal/http_client
import llm_wire/types

pub fn http_deadline_keeps_deadline_classification_test() {
  http_client.wire_error(error.Failure(
    error.DeadlineExceeded,
    error.MayHaveBeenSent,
  ))
  |> should.equal(types.DeadlineExceeded(types.OverallDeadline))
}

pub fn diagnostic_text_does_not_determine_failure_category_test() {
  http_client.wire_error(error.Failure(
    error.InvalidConfig("overall deadline exceeded"),
    error.NotSubmitted,
  ))
  |> should.equal(
    types.HttpFailure(error.InvalidConfig("overall deadline exceeded")),
  )
  http_client.wire_error(error.Failure(
    error.ConnectionFailed(error.ConnectionRefused),
    error.NotSubmitted,
  ))
  |> should.equal(
    types.HttpFailure(error.ConnectionFailed(error.ConnectionRefused)),
  )
}
