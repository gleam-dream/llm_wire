//// Pure assessment of whether another provider attempt could help.
////
//// The caller owns retry scheduling and must separately consider `RetryEvidence`,
//// cancellation, provider effects, retry hints, and its remaining budget.
//// `MayHelp` does not authorize retrying an ambiguous or partially observed call.

import gleam/option.{None, Some}
import llm_wire/types

/// Whether another attempt could succeed without changing the request or setup.
pub type RetryProspect {
  /// The failure may be transient. Another attempt is not guaranteed to succeed.
  MayHelp
  /// The request, configuration, limits, account, or cancellation must change.
  WillNotHelpUnchanged
  /// The available structured error does not establish a retry prospect.
  Unknown
}

/// Assess the failure cause independently of request reachability and progress.
///
/// HTTP status assessment ignores diagnostic bodies and retry hints. A 429 may
/// mean a temporary rate limit or exhausted billing; a status alone cannot tell.
/// Transport errors and deadlines may be transient, but the current error types
/// cannot distinguish permanent transport failures or an insufficient timeout.
///
/// Provider codes are matched exactly within their provider. Unknown codes and
/// custom provider codes return `Unknown`; diagnostic prose is never parsed.
pub fn assess(
  provider: types.Provider,
  error: types.WireError,
) -> RetryProspect {
  case error {
    types.ConfigurationError(_)
    | types.PreparationError(_)
    | types.ResourceLimitExceeded(..)
    | types.CancelledLocally -> WillNotHelpUnchanged
    types.TransportError(_) | types.DeadlineExceeded(_) -> MayHelp
    types.ProtocolError(_) | types.OutputValidationError(_) -> Unknown
    types.HttpStatusError(status, _, _) -> assess_status(provider, status)
    types.ProviderError(None, _) -> Unknown
    types.ProviderError(Some(code), _) -> assess_code(provider, code)
  }
}

fn assess_status(provider: types.Provider, status: Int) -> RetryProspect {
  case status {
    408 | 429 | 500 | 502 | 503 | 504 -> MayHelp
    400 | 401 | 403 | 404 | 405 | 406 | 410 | 413 | 415 | 422 | 501 | 505 ->
      WillNotHelpUnchanged
    529 ->
      case provider {
        types.Anthropic -> MayHelp
        _ -> Unknown
      }
    _ -> Unknown
  }
}

fn assess_code(provider: types.Provider, code: String) -> RetryProspect {
  case provider {
    types.OpenAI -> assess_openai_code(code)
    types.Anthropic -> assess_anthropic_code(code)
    types.Google -> assess_google_code(code)
    types.Custom(_) -> Unknown
  }
}

// Verified against the provider's error guide and response-error schema:
// https://developers.openai.com/api/docs/guides/error-codes
// https://github.com/openai/openai-python/blob/main/src/openai/types/responses/response_error.py
fn assess_openai_code(code: String) -> RetryProspect {
  case code {
    "server_error"
    | "rate_limit_exceeded"
    | "slow_down"
    | "server_is_overloaded" -> MayHelp
    "invalid_prompt"
    | "insufficient_quota"
    | "credit_balance_exhausted"
    | "organization_spend_limit_exceeded"
    | "project_spend_limit_exceeded"
    | "organization_usage_limit_exceeded" -> WillNotHelpUnchanged
    _ -> Unknown
  }
}

// https://platform.claude.com/docs/en/api/errors
fn assess_anthropic_code(code: String) -> RetryProspect {
  case code {
    "rate_limit_error" | "api_error" | "timeout_error" | "overloaded_error" ->
      MayHelp
    "invalid_request_error"
    | "authentication_error"
    | "billing_error"
    | "permission_error"
    | "not_found_error"
    | "request_too_large" -> WillNotHelpUnchanged
    _ -> Unknown
  }
}

// Canonical status strings retained by the GenerateContent adapter:
// https://ai.google.dev/gemini-api/docs/troubleshooting
// https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/api-errors
fn assess_google_code(code: String) -> RetryProspect {
  case code {
    "RESOURCE_EXHAUSTED" | "INTERNAL" | "UNAVAILABLE" | "DEADLINE_EXCEEDED" ->
      MayHelp
    "INVALID_ARGUMENT"
    | "FAILED_PRECONDITION"
    | "UNAUTHENTICATED"
    | "PERMISSION_DENIED"
    | "NOT_FOUND" -> WillNotHelpUnchanged
    _ -> Unknown
  }
}
