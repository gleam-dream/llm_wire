//// An error status carries the provider's own error code and message, read
//// from the error body each built-in provider sends, so a caller can tell
//// an exhausted quota from a rate limit, or a prompt that is too long from
//// a bad key, without parsing the body.

import gleam/option.{None, Some}
import http_test_helpers
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/google
import llm_wire/message
import llm_wire/openai
import llm_wire/testing

/// Serve `body` exactly as given with `status`.
fn fail_with(
  config: llm_wire.Config,
  status: Int,
  body: String,
) -> llm_wire.Failure {
  let assert Ok(prepared) =
    llm_wire.prepare(config, llm_wire.request("fixture", [message.User("hi")]))
  let reply = testing.http_status(message.Custom("raw"), status, body)
  let assert Error(failure) = http_test_helpers.run_reply(prepared, reply)
  failure
}

fn openai_config() -> llm_wire.Config {
  openai.new("k") |> openai.config
}

fn anthropic_config() -> llm_wire.Config {
  anthropic.new("k") |> anthropic.config
}

fn google_config() -> llm_wire.Config {
  google.new("k") |> google.config
}

// --- OpenAI ------------------------------------------------------------------

const openai_quota =
  "{
  \"error\": {
    \"message\": \"You exceeded your current quota, please check your plan and billing details.\",
    \"type\": \"insufficient_quota\",
    \"param\": null,
    \"code\": \"insufficient_quota\"
  }
}"

/// OpenAI answers an exhausted quota with 429, the status of a rate limit.
/// Only the code tells them apart, and waiting does not refill a quota.
pub fn openai_quota_is_not_a_rate_limit_test() {
  let failure = fail_with(openai_config(), 429, openai_quota)
  let assert error.Status(
    status: 429,
    code: Some("insufficient_quota"),
    message: Some(
      "You exceeded your current quota, please check your plan and billing details.",
    ),
    ..,
  ) = failure.error
  assert llm_wire.advise(failure).prospect == llm_wire.WillNotHelpUnchanged
}

pub fn openai_rate_limit_may_help_test() {
  let body =
    "{\"error\":{\"message\":\"Rate limit reached for gpt-5 in organization org-x on tokens per min (TPM): Limit 30000, Used 30000, Requested 100.\",\"type\":\"tokens\",\"param\":null,\"code\":\"rate_limit_exceeded\"}}"
  let failure = fail_with(openai_config(), 429, body)
  let assert error.Status(code: Some("rate_limit_exceeded"), ..) = failure.error
  assert llm_wire.advise(failure).prospect == llm_wire.MayHelp
}

pub fn openai_context_length_names_its_code_test() {
  let body =
    "{\"error\":{\"message\":\"Your input exceeds the context window of this model. Please adjust your input and try again.\",\"type\":\"invalid_request_error\",\"param\":\"input\",\"code\":\"context_length_exceeded\"}}"
  let failure = fail_with(openai_config(), 400, body)
  let assert error.Status(
    status: 400,
    code: Some("context_length_exceeded"),
    message: Some(_),
    ..,
  ) = failure.error
  assert llm_wire.advise(failure).prospect == llm_wire.WillNotHelpUnchanged
}

/// OpenAI sends `"code": null` for some errors; the type names them then.
pub fn openai_null_code_falls_back_to_the_type_test() {
  let body =
    "{\"error\":{\"message\":\"Incorrect API key provided: sk-...abcd.\",\"type\":\"invalid_request_error\",\"param\":null,\"code\":null}}"
  let failure = fail_with(openai_config(), 401, body)
  let assert error.Status(status: 401, code: Some("invalid_request_error"), ..) =
    failure.error
}

// --- Anthropic ---------------------------------------------------------------

pub fn anthropic_overload_names_its_type_test() {
  let body =
    "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"},\"request_id\":\"req_011CSHoEeqs5C35K2UUqR7Fy\"}"
  let failure = fail_with(anthropic_config(), 529, body)
  let assert error.Status(
    status: 529,
    code: Some("overloaded_error"),
    message: Some("Overloaded"),
    ..,
  ) = failure.error
  assert llm_wire.advise(failure).prospect == llm_wire.MayHelp
}

pub fn anthropic_prompt_too_long_names_its_type_test() {
  let body =
    "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"prompt is too long: 208310 tokens > 200000 maximum\"},\"request_id\":\"req_011CT\"}"
  let failure = fail_with(anthropic_config(), 400, body)
  let assert error.Status(
    code: Some("invalid_request_error"),
    message: Some("prompt is too long: 208310 tokens > 200000 maximum"),
    ..,
  ) = failure.error
}

// --- Google ------------------------------------------------------------------

const google_quota =
  "{
  \"error\": {
    \"code\": 429,
    \"message\": \"You exceeded your current quota, please check your plan and billing details.\",
    \"status\": \"RESOURCE_EXHAUSTED\",
    \"details\": [
      {
        \"@type\": \"type.googleapis.com/google.rpc.RetryInfo\",
        \"retryDelay\": \"35s\"
      }
    ]
  }
}"

pub fn google_status_names_its_canonical_code_test() {
  let failure = fail_with(google_config(), 429, google_quota)
  let assert error.Status(
    status: 429,
    code: Some("RESOURCE_EXHAUSTED"),
    message: Some(
      "You exceeded your current quota, please check your plan and billing details.",
    ),
    ..,
  ) = failure.error
}

pub fn google_invalid_argument_will_not_help_test() {
  let body =
    "{\"error\":{\"code\":400,\"message\":\"API key not valid. Please pass a valid API key.\",\"status\":\"INVALID_ARGUMENT\"}}"
  let failure = fail_with(google_config(), 400, body)
  let assert error.Status(code: Some("INVALID_ARGUMENT"), ..) = failure.error
  assert llm_wire.advise(failure).prospect == llm_wire.WillNotHelpUnchanged
}

// --- bodies without an error envelope ----------------------------------------

/// A proxy's HTML page has no provider code; the body is kept as sent and
/// advice falls back to the status.
pub fn a_body_without_an_envelope_keeps_only_the_status_test() {
  let body = "<html><body>502 Bad Gateway</body></html>"
  let failure = fail_with(openai_config(), 502, body)
  let assert error.Status(
    status: 502,
    code: None,
    message: None,
    body: found,
    ..,
  ) = failure.error
  assert found == body
  assert llm_wire.advise(failure).prospect == llm_wire.MayHelp
}

/// The one-line description names the provider's code. It leaves the
/// provider's message out: an authentication message can quote part of the
/// key.
pub fn describe_names_the_provider_code_test() {
  let failure = fail_with(openai_config(), 429, openai_quota)
  let line = error.describe(failure.error)
  assert line == "Provider answered with HTTP status 429 insufficient_quota"
}
