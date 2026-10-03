import gleeunit/should
import http_gun/error as http_error
import llm_wire/error
import llm_wire/internal/http_client

pub fn http_deadline_keeps_deadline_classification_test() {
  http_client.wire_error(http_error.new(
    http_error.DeadlineExceeded,
    http_error.MaybeSent,
  ))
  |> should.equal(error.DeadlineExceeded(error.WholeCall))
}

pub fn diagnostic_text_does_not_determine_failure_category_test() {
  // Another timeout is not the call's whole-call deadline. The error now
  // carries HTTP Gun's opaque failure itself, not only its reason.
  let idle = http_error.new(http_error.IdleTimeout, http_error.NotSent)
  http_client.wire_error(idle) |> should.equal(error.Http(idle))
  let refused =
    http_error.new(
      http_error.ConnectionFailed(http_error.ConnectionRefused),
      http_error.NotSent,
    )
  let assert error.Http(failure) = http_client.wire_error(refused)
  http_error.reason(failure)
  |> should.equal(http_error.ConnectionFailed(http_error.ConnectionRefused))
}
