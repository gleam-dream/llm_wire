//// Failures and retries: read a `Failure`, ask `advise` whether another
//// attempt may help and who chooses the wait, and branch on the closed `Kind`.

import gleam/io
import gleam/option.{None, Some}
import gleam/time/duration
import llm_wire
import llm_wire/error
import llm_wire/limit
import llm_wire/message
import llm_wire/openai
import llm_wire/testing
import usage_support.{prepared, scripted}

/// A closed `Kind` needs no catch-all arm: the compiler checks every case.
fn describe_kind(failure: llm_wire.Failure) -> String {
  case error.kind(failure.error) {
    error.Transport -> "the exchange did not complete"
    error.ProviderError -> "the provider answered with an error"
    error.ContentPolicy -> "the prompt must change"
    error.UnusableResponse -> "the response cannot be used"
    error.OverLimit -> "a configured bound stopped the call"
    error.Ended -> "the caller ended the call"
  }
}

pub fn main() -> Nil {
  // `testing.failure` builds a `Failure` without running a call.
  let limited =
    testing.failure(
      message.OpenAI,
      error.Status(429, "slow down", Some(duration.seconds(2))),
    )
  // The provider named a wait: the caller may snooze without counting an attempt.
  let assert llm_wire.RetryAdvice(
    prospect: llm_wire.MayHelp,
    delay: llm_wire.ProviderDelay(wait),
  ) = llm_wire.advise(limited)
  let assert True = wait == duration.seconds(2)

  // No named wait: the caller's own backoff applies.
  let unavailable =
    testing.failure(message.OpenAI, error.Status(503, "busy", None))
  let assert llm_wire.RetryAdvice(
    prospect: llm_wire.MayHelp,
    delay: llm_wire.Backoff,
  ) = llm_wire.advise(unavailable)

  // A safety stop will not improve on retry; the prompt must change.
  let filtered =
    testing.failure(
      message.OpenAI,
      error.ContentFiltered(error.InOutput, "SAFETY"),
    )
  let assert llm_wire.RetryAdvice(prospect: llm_wire.WillNotHelpUnchanged, ..) =
    llm_wire.advise(filtered)
  let assert error.ContentPolicy = error.kind(filtered.error)

  // A bound that was exceeded is a configuration decision, not a retry.
  let over =
    testing.failure(
      message.OpenAI,
      error.LimitExceeded(limit.QueueCount, 500, 501),
    )
  let assert error.OverLimit = error.kind(over.error)

  // The same classification applies to a failure produced by a real call.
  let config = openai.new("sk-example") |> openai.config
  let request = llm_wire.request("gpt-5", [llm_wire.user("Hello")])
  let call = prepared(config, request)
  let assert Error(
    llm_wire.Failure(
      error: error.ContentFiltered(stage: error.InOutput, ..),
      sent: llm_wire.Completed,
      ..,
    ) as run_failure,
  ) = {
    use client <- scripted([
      testing.exchange(
        call,
        testing.events_for(message.OpenAI, testing.content_filtered("partial")),
      ),
    ])
    llm_wire.run(client, call)
  }
  io.println(
    llm_wire.describe_failure(run_failure)
    <> " -> "
    <> describe_kind(run_failure),
  )
}
