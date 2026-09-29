import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import llm_wire/retry
import llm_wire/types

pub fn service_unavailable_may_help_test() {
  retry.assess(types.OpenAI, types.HttpStatusError(503, "", None))
  |> should.equal(retry.MayHelp)
}

pub fn local_error_causes_have_separate_prospects_test() {
  let cases = [
    #(types.ConfigurationError("endpoint"), retry.WillNotHelpUnchanged),
    #(types.PreparationError("missing result"), retry.WillNotHelpUnchanged),
    #(
      types.ResourceLimitExceeded("request_bytes", 1024, 2048),
      retry.WillNotHelpUnchanged,
    ),
    #(types.CancelledLocally, retry.WillNotHelpUnchanged),
    #(types.TransportError("connection reset"), retry.MayHelp),
    #(types.DeadlineExceeded(types.OverallDeadline), retry.MayHelp),
    #(types.DeadlineExceeded(types.IdleDeadline), retry.MayHelp),
    #(types.DeadlineExceeded(types.ReadDeadline), retry.MayHelp),
    #(types.ProtocolError("malformed frame"), retry.Unknown),
    #(types.OutputValidationError("missing field"), retry.Unknown),
  ]
  list.each(cases, fn(row) {
    let #(error, expected) = row
    retry.assess(types.OpenAI, error) |> should.equal(expected)
  })
}

pub fn common_http_statuses_work_for_every_provider_test() {
  let cases = [
    #(408, retry.MayHelp),
    #(429, retry.MayHelp),
    #(500, retry.MayHelp),
    #(502, retry.MayHelp),
    #(503, retry.MayHelp),
    #(504, retry.MayHelp),
    #(400, retry.WillNotHelpUnchanged),
    #(401, retry.WillNotHelpUnchanged),
    #(403, retry.WillNotHelpUnchanged),
    #(404, retry.WillNotHelpUnchanged),
    #(405, retry.WillNotHelpUnchanged),
    #(406, retry.WillNotHelpUnchanged),
    #(410, retry.WillNotHelpUnchanged),
    #(413, retry.WillNotHelpUnchanged),
    #(415, retry.WillNotHelpUnchanged),
    #(422, retry.WillNotHelpUnchanged),
    #(501, retry.WillNotHelpUnchanged),
    #(505, retry.WillNotHelpUnchanged),
    #(200, retry.Unknown),
    #(301, retry.Unknown),
    #(409, retry.Unknown),
    #(418, retry.Unknown),
    #(599, retry.Unknown),
  ]
  list.each(providers(), fn(provider) {
    list.each(cases, fn(row) {
      let #(status, expected) = row
      retry.assess(provider, types.HttpStatusError(status, "", None))
      |> should.equal(expected)
    })
  })
}

pub fn overloaded_status_is_scoped_to_anthropic_test() {
  list.each(providers(), fn(provider) {
    let expected = case provider {
      types.Anthropic -> retry.MayHelp
      _ -> retry.Unknown
    }
    retry.assess(provider, types.HttpStatusError(529, "", None))
    |> should.equal(expected)
  })
}

pub fn documented_provider_codes_distinguish_transience_from_required_changes_test() {
  let cases = [
    #(types.OpenAI, "server_error", retry.MayHelp),
    #(types.OpenAI, "rate_limit_exceeded", retry.MayHelp),
    #(types.OpenAI, "slow_down", retry.MayHelp),
    #(types.OpenAI, "server_is_overloaded", retry.MayHelp),
    #(types.OpenAI, "invalid_prompt", retry.WillNotHelpUnchanged),
    #(types.OpenAI, "insufficient_quota", retry.WillNotHelpUnchanged),
    #(types.OpenAI, "credit_balance_exhausted", retry.WillNotHelpUnchanged),
    #(
      types.OpenAI,
      "organization_spend_limit_exceeded",
      retry.WillNotHelpUnchanged,
    ),
    #(types.OpenAI, "project_spend_limit_exceeded", retry.WillNotHelpUnchanged),
    #(
      types.OpenAI,
      "organization_usage_limit_exceeded",
      retry.WillNotHelpUnchanged,
    ),
    #(types.Anthropic, "overloaded_error", retry.MayHelp),
    #(types.Anthropic, "rate_limit_error", retry.MayHelp),
    #(types.Anthropic, "api_error", retry.MayHelp),
    #(types.Anthropic, "timeout_error", retry.MayHelp),
    #(types.Anthropic, "invalid_request_error", retry.WillNotHelpUnchanged),
    #(types.Anthropic, "authentication_error", retry.WillNotHelpUnchanged),
    #(types.Anthropic, "billing_error", retry.WillNotHelpUnchanged),
    #(types.Anthropic, "permission_error", retry.WillNotHelpUnchanged),
    #(types.Anthropic, "not_found_error", retry.WillNotHelpUnchanged),
    #(types.Anthropic, "request_too_large", retry.WillNotHelpUnchanged),
    #(types.Google, "RESOURCE_EXHAUSTED", retry.MayHelp),
    #(types.Google, "INTERNAL", retry.MayHelp),
    #(types.Google, "UNAVAILABLE", retry.MayHelp),
    #(types.Google, "DEADLINE_EXCEEDED", retry.MayHelp),
    #(types.Google, "INVALID_ARGUMENT", retry.WillNotHelpUnchanged),
    #(types.Google, "FAILED_PRECONDITION", retry.WillNotHelpUnchanged),
    #(types.Google, "UNAUTHENTICATED", retry.WillNotHelpUnchanged),
    #(types.Google, "PERMISSION_DENIED", retry.WillNotHelpUnchanged),
    #(types.Google, "NOT_FOUND", retry.WillNotHelpUnchanged),
  ]
  list.each(cases, fn(row) {
    let #(provider, code, expected) = row
    retry.assess(provider, types.ProviderError(Some(code), ""))
    |> should.equal(expected)
  })
}

pub fn unknown_codes_never_guess_from_names_or_diagnostic_text_test() {
  let cases = [
    #(types.OpenAI, "rate_limit"),
    #(types.OpenAI, "overloaded_error"),
    #(types.Anthropic, "server_error"),
    #(types.Anthropic, "conflict_error"),
    #(types.Google, "unavailable"),
    #(types.Google, "ABORTED"),
    #(types.Custom("anthropic"), "overloaded_error"),
    #(types.Custom("openai"), "rate_limit_exceeded"),
    #(types.Custom("google"), "UNAVAILABLE"),
  ]
  list.each(cases, fn(row) {
    let #(provider, code) = row
    retry.assess(
      provider,
      types.ProviderError(Some(code), "Temporary failure: retry now"),
    )
    |> should.equal(retry.Unknown)
  })
  list.each(providers(), fn(provider) {
    retry.assess(provider, types.ProviderError(None, "rate_limit_exceeded"))
    |> should.equal(retry.Unknown)
    retry.assess(provider, types.ProviderError(Some("new_code"), "retry"))
    |> should.equal(retry.Unknown)
  })
}

pub fn status_prospect_does_not_infer_policy_from_body_or_retry_hint_test() {
  // A status alone is ambiguous, even if a body resembles a permanent quota
  // error. Only explicit ProviderError codes are provider-classified.
  retry.assess(
    types.OpenAI,
    types.HttpStatusError(
      429,
      "{\"error\":{\"code\":\"insufficient_quota\"}}",
      Some(types.RetryDelaySeconds(60)),
    ),
  )
  |> should.equal(retry.MayHelp)
  retry.assess(
    types.OpenAI,
    types.HttpStatusError(400, "retry later", Some(types.RetryDelaySeconds(1))),
  )
  |> should.equal(retry.WillNotHelpUnchanged)
}

fn providers() -> List(types.Provider) {
  [types.OpenAI, types.Anthropic, types.Google, types.Custom("example")]
}
