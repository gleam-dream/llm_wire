//// Retry advice. `retry.assess(provider, error)` became
//// `llm_wire.advise(failure)`: the provider and error now travel in the
//// `Failure`, and the advice also carries the `Retry-After` delay.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import http_gun/destination
import http_gun/error as http_error
import json/blueprint/codec
import llm_wire
import llm_wire/error
import llm_wire/limit
import llm_wire/message

fn failure(
  provider: message.Provider,
  problem: error.Error,
) -> llm_wire.Failure {
  llm_wire.Failure(
    error: problem,
    sent: llm_wire.MaybeSent,
    partial_output: False,
    provider:,
    usage: None,
  )
}

fn prospect(
  provider: message.Provider,
  problem: error.Error,
) -> llm_wire.RetryProspect {
  llm_wire.advise(failure(provider, problem)).prospect
}

fn status(code: Int) -> error.Error {
  error.Status(code, "", None)
}

pub fn service_unavailable_may_help_test() {
  prospect(message.OpenAI, status(503)) |> should.equal(llm_wire.MayHelp)
}

pub fn local_error_causes_have_separate_prospects_test() {
  // Configuration and preparation errors are now `error.PrepareError`
  // values returned by `prepare`; they never become a `Failure`, so they
  // have no retry advice. A resource limit at prepare is
  // `RequestTooLarge`; at runtime it is `LimitExceeded`, checked here.
  let cases = [
    #(
      error.LimitExceeded(limit.RequestBytes, 1024, 2048),
      llm_wire.WillNotHelpUnchanged,
    ),
    #(error.Cancelled, llm_wire.WillNotHelpUnchanged),
    // `TransportError("connection reset")` is now an HTTP Gun failure.
    #(
      error.Http(http_error.new(
        http_error.RequestFailed(http_error.ConnectionReset),
        http_error.MaybeSent,
      )),
      llm_wire.MayHelp,
    ),
    // The overall and idle deadlines became the whole-call, first-token
    // and idle-gap timers; the read deadline is gone.
    #(error.DeadlineExceeded(error.WholeCall), llm_wire.MayHelp),
    #(error.DeadlineExceeded(error.FirstToken), llm_wire.MayHelp),
    #(error.DeadlineExceeded(error.IdleGap), llm_wire.MayHelp),
    #(error.Protocol("malformed frame"), llm_wire.Unknown),
    #(
      error.InvalidOutput("{}", error.DecodeRejected(codec_failure())),
      llm_wire.Unknown,
    ),
    #(error.Stopped, llm_wire.Unknown),
  ]
  list.each(cases, fn(row) {
    let #(problem, expected) = row
    prospect(message.OpenAI, problem) |> should.equal(expected)
  })
}

fn codec_failure() -> codec.DecodeError {
  let assert Error(problem) =
    codec.decode_json(codec.int(), "\"missing field\"")
  problem
}

pub fn common_http_statuses_work_for_every_provider_test() {
  let cases = [
    #(408, llm_wire.MayHelp),
    #(429, llm_wire.MayHelp),
    #(500, llm_wire.MayHelp),
    #(502, llm_wire.MayHelp),
    #(503, llm_wire.MayHelp),
    #(504, llm_wire.MayHelp),
    #(400, llm_wire.WillNotHelpUnchanged),
    #(401, llm_wire.WillNotHelpUnchanged),
    #(403, llm_wire.WillNotHelpUnchanged),
    #(404, llm_wire.WillNotHelpUnchanged),
    #(405, llm_wire.WillNotHelpUnchanged),
    #(406, llm_wire.WillNotHelpUnchanged),
    #(410, llm_wire.WillNotHelpUnchanged),
    #(413, llm_wire.WillNotHelpUnchanged),
    #(415, llm_wire.WillNotHelpUnchanged),
    #(422, llm_wire.WillNotHelpUnchanged),
    #(501, llm_wire.WillNotHelpUnchanged),
    #(505, llm_wire.WillNotHelpUnchanged),
    #(200, llm_wire.Unknown),
    #(301, llm_wire.Unknown),
    #(409, llm_wire.Unknown),
    #(418, llm_wire.Unknown),
    #(599, llm_wire.Unknown),
  ]
  list.each(providers(), fn(provider) {
    list.each(cases, fn(row) {
      let #(code, expected) = row
      prospect(provider, status(code)) |> should.equal(expected)
    })
  })
}

pub fn overloaded_status_is_scoped_to_anthropic_test() {
  list.each(providers(), fn(provider) {
    let expected = case provider {
      message.Anthropic -> llm_wire.MayHelp
      _ -> llm_wire.Unknown
    }
    prospect(provider, status(529)) |> should.equal(expected)
  })
}

pub fn documented_provider_codes_distinguish_transience_from_required_changes_test() {
  let cases = [
    #(message.OpenAI, "server_error", llm_wire.MayHelp),
    #(message.OpenAI, "rate_limit_exceeded", llm_wire.MayHelp),
    #(message.OpenAI, "slow_down", llm_wire.MayHelp),
    #(message.OpenAI, "server_is_overloaded", llm_wire.MayHelp),
    #(message.OpenAI, "invalid_prompt", llm_wire.WillNotHelpUnchanged),
    #(message.OpenAI, "insufficient_quota", llm_wire.WillNotHelpUnchanged),
    #(message.OpenAI, "credit_balance_exhausted", llm_wire.WillNotHelpUnchanged),
    #(
      message.OpenAI,
      "organization_spend_limit_exceeded",
      llm_wire.WillNotHelpUnchanged,
    ),
    #(
      message.OpenAI,
      "project_spend_limit_exceeded",
      llm_wire.WillNotHelpUnchanged,
    ),
    #(
      message.OpenAI,
      "organization_usage_limit_exceeded",
      llm_wire.WillNotHelpUnchanged,
    ),
    #(message.Anthropic, "overloaded_error", llm_wire.MayHelp),
    #(message.Anthropic, "rate_limit_error", llm_wire.MayHelp),
    #(message.Anthropic, "api_error", llm_wire.MayHelp),
    #(message.Anthropic, "timeout_error", llm_wire.MayHelp),
    #(message.Anthropic, "invalid_request_error", llm_wire.WillNotHelpUnchanged),
    #(message.Anthropic, "authentication_error", llm_wire.WillNotHelpUnchanged),
    #(message.Anthropic, "billing_error", llm_wire.WillNotHelpUnchanged),
    #(message.Anthropic, "permission_error", llm_wire.WillNotHelpUnchanged),
    #(message.Anthropic, "not_found_error", llm_wire.WillNotHelpUnchanged),
    #(message.Anthropic, "request_too_large", llm_wire.WillNotHelpUnchanged),
    #(message.Google, "RESOURCE_EXHAUSTED", llm_wire.MayHelp),
    #(message.Google, "INTERNAL", llm_wire.MayHelp),
    #(message.Google, "UNAVAILABLE", llm_wire.MayHelp),
    #(message.Google, "DEADLINE_EXCEEDED", llm_wire.MayHelp),
    #(message.Google, "INVALID_ARGUMENT", llm_wire.WillNotHelpUnchanged),
    #(message.Google, "FAILED_PRECONDITION", llm_wire.WillNotHelpUnchanged),
    #(message.Google, "UNAUTHENTICATED", llm_wire.WillNotHelpUnchanged),
    #(message.Google, "PERMISSION_DENIED", llm_wire.WillNotHelpUnchanged),
    #(message.Google, "NOT_FOUND", llm_wire.WillNotHelpUnchanged),
  ]
  list.each(cases, fn(row) {
    let #(provider, code, expected) = row
    prospect(provider, error.Provider(Some(code), ""))
    |> should.equal(expected)
  })
}

pub fn unknown_codes_never_guess_from_names_or_diagnostic_text_test() {
  let cases = [
    #(message.OpenAI, "rate_limit"),
    #(message.OpenAI, "overloaded_error"),
    #(message.Anthropic, "server_error"),
    #(message.Anthropic, "conflict_error"),
    #(message.Google, "unavailable"),
    #(message.Google, "ABORTED"),
    #(message.Custom("anthropic"), "overloaded_error"),
    #(message.Custom("openai"), "rate_limit_exceeded"),
    #(message.Custom("google"), "UNAVAILABLE"),
  ]
  list.each(cases, fn(row) {
    let #(provider, code) = row
    prospect(
      provider,
      error.Provider(Some(code), "Temporary failure: retry now"),
    )
    |> should.equal(llm_wire.Unknown)
  })
  list.each(providers(), fn(provider) {
    prospect(provider, error.Provider(None, "rate_limit_exceeded"))
    |> should.equal(llm_wire.Unknown)
    prospect(provider, error.Provider(Some("new_code"), "retry"))
    |> should.equal(llm_wire.Unknown)
  })
}

pub fn status_prospect_does_not_infer_policy_from_body_or_retry_hint_test() {
  // A status alone is ambiguous, even if a body resembles a permanent quota
  // error. Only explicit provider error codes are provider-classified. The
  // advice now also returns the status's `Retry-After` delay unchanged.
  llm_wire.advise(failure(
    message.OpenAI,
    error.Status(
      429,
      "{\"error\":{\"code\":\"insufficient_quota\"}}",
      Some(duration.seconds(60)),
    ),
  ))
  |> should.equal(llm_wire.RetryAdvice(
    llm_wire.MayHelp,
    Some(duration.seconds(60)),
  ))
  llm_wire.advise(failure(
    message.OpenAI,
    error.Status(400, "retry later", Some(duration.seconds(1))),
  ))
  |> should.equal(llm_wire.RetryAdvice(
    llm_wire.WillNotHelpUnchanged,
    Some(duration.seconds(1)),
  ))
}

// --- HTTP Gun failures ---------------------------------------------------------

fn http_failure(
  reason: http_error.Reason,
  headers: List(#(String, String)),
) -> llm_wire.Failure {
  failure(
    message.OpenAI,
    error.Http(
      http_error.new(reason, http_error.MaybeSent)
      |> http_error.with_headers(headers),
    ),
  )
}

pub fn http_failures_are_classified_by_their_kind_test() {
  let cases = [
    #(
      http_error.InvalidRequest(http_error.InvalidHeader),
      http_error.InvalidInput,
      llm_wire.WillNotHelpUnchanged,
    ),
    #(
      http_error.DestinationRejected(destination.PlaintextRefused(
        destination.Private,
      )),
      http_error.Refused,
      llm_wire.WillNotHelpUnchanged,
    ),
    #(http_error.AdmissionFull, http_error.Unavailable, llm_wire.MayHelp),
    #(
      http_error.ConnectionFailed(http_error.ConnectionRefused),
      http_error.Network,
      llm_wire.MayHelp,
    ),
    #(http_error.ConnectTimeout, http_error.TimedOut, llm_wire.MayHelp),
    #(
      http_error.LimitExceeded(http_error.ResponseBodyBytes, 10, 11),
      http_error.TooLarge,
      llm_wire.WillNotHelpUnchanged,
    ),
    #(
      http_error.Cancelled,
      http_error.CancelledLocally,
      llm_wire.WillNotHelpUnchanged,
    ),
    #(http_error.ReadConflict, http_error.Misuse, llm_wire.WillNotHelpUnchanged),
    #(
      http_error.PlaybackExhausted,
      http_error.Playback,
      llm_wire.WillNotHelpUnchanged,
    ),
  ]
  list.each(cases, fn(row) {
    let #(reason, kind, expected) = row
    let failed = http_failure(reason, [])
    let assert error.Http(inner) = failed.error
    http_error.kind(inner) |> should.equal(kind)
    llm_wire.advise(failed)
    |> should.equal(llm_wire.RetryAdvice(expected, None))
  })
}

fn after(headers: List(#(String, String))) -> Option(duration.Duration) {
  llm_wire.advise(http_failure(
    http_error.RequestFailed(http_error.PeerClosed),
    headers,
  )).after
}

pub fn http_failures_read_retry_after_in_seconds_test() {
  after([#("retry-after", "5")]) |> should.equal(Some(duration.seconds(5)))
  // Header names match case-insensitively.
  after([#("Retry-After", " 12 ")]) |> should.equal(Some(duration.seconds(12)))
  after([]) |> should.equal(None)
  after([#("retry-after", "soon")]) |> should.equal(None)
  after([#("retry-after", "-3")]) |> should.equal(None)
}

pub fn http_failures_read_retry_after_as_an_http_date_test() {
  let at =
    timestamp.system_time()
    |> timestamp.add(duration.seconds(120))
    |> timestamp.to_http_date
  let assert Some(delay) = after([#("retry-after", at)])
  let #(seconds, _) = duration.to_seconds_and_nanoseconds(delay)
  { seconds >= 115 && seconds <= 120 } |> should.be_true
  // A date in the past asks for no delay.
  after([#("retry-after", "Wed, 21 Oct 2015 07:28:00 GMT")])
  |> should.equal(Some(duration.seconds(0)))
}

fn providers() -> List(message.Provider) {
  [message.OpenAI, message.Anthropic, message.Google, message.Custom("example")]
}
