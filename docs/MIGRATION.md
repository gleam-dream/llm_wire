# Migrating from LLM Wire 0.2 to 0.3

LLM Wire 0.3.0 is a breaking release. Change the dependency to `llm_wire >= 0.3.0 and < 0.4.0` in `gleam.toml`, then work through the sections below in order. The first ones affect most applications.

| Change                                                                                        | Who must act                                                             |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| [New dependency ranges](#new-dependency-ranges)                                               | Every application                                                        |
| [The whole-call timeout is a `Duration`](#the-whole-call-timeout-is-a-duration)               | Code that calls `with_call_timeout` or `classify.with_timeout`           |
| [`error.Status` carries the provider's code](#errorstatus-carries-the-providers-code)         | Code that matches or builds `error.Status`                               |
| [An unknown stop reason is an outcome](#an-unknown-stop-reason-is-an-outcome)                 | Code that matches `llm_wire.Outcome` or `telemetry.Outcome` exhaustively |
| [`ProviderExtension` is `UnrecognizedEvent`](#providerextension-is-unrecognizedevent)         | Code that matches `message.Progress`, and custom adapters                |
| [Thinking continues a tool round](#thinking-continues-a-tool-round)                           | Code that matches `ThinkingInToolRound`, or rebuilds assistant turns     |
| [Behaviour changes without a signature change](#behaviour-changes-without-a-signature-change) | Applications that rely on the old behaviour                              |

New in 0.3.0 and not breaking: `provider.unrecognized_stop` and `testing.unrecognized_stop`.

## New dependency ranges

**What changed.** LLM Wire 0.3.0 requires `http_gun >= 0.4.0 and < 0.5.0`, `sinal >= 0.2.0 and < 0.3.0` and `json_blueprint >= 3.0.0 and < 4.0.0`. Each of these releases is breaking on its own; read its migration guide too: [HTTP Gun](https://github.com/gleam-dream/http_gun/blob/main/docs/MIGRATION.md), [Sinal](https://github.com/gleam-dream/sinal/blob/main/docs/MIGRATION.md) and [JSON Blueprint](https://github.com/gleam-dream/json_blueprint/blob/main/docs/MIGRATION.md).

**What to do.** Update the ranges of the packages your application declares directly, usually `http_gun`, then run `gleam deps update llm_wire http_gun sinal json_blueprint` and commit `manifest.toml`.

**What this means for LLM Wire calls.**

- Every HTTP Gun request now has a finite timeout, 30 seconds unless the client view sets another. A generation call replaces it with its own whole-call budget, so streams still run for the budget (600 seconds by default). Classification also sets its own timeout. Transcription runs under the timeout of the client view you pass: set a longer one with `http_gun.with_timeout` for long audio.
- A Sinal handler is detached when the process that attached it exits. Attach `telemetry` observers from a long-lived process, such as a supervised actor, not from a request handler.
- Tool arguments, replay data and classification responses are parsed with JSON Blueprint's default limits: 1 MiB of text, nested at most 128 levels deep. Stored replay data and transcription responses are limited to 64 levels.

## The whole-call timeout is a `Duration`

**What changed.** `llm_wire.with_call_timeout` and `classify.with_timeout` take a `Duration` instead of a `Bound`. `Infinity` is no longer possible for the whole call. `with_first_token_timeout` and `with_idle_timeout` still take a `Bound` and still accept `Infinity`.

**Why.** HTTP Gun no longer has an unbounded request. An unbounded whole call would have fallen back to the client's 30 second default and cut long streams ([ADR 0025](https://github.com/gleam-dream/llm_wire/blob/main/docs/adr/0025-keep-the-whole-call-finite.md)).

**What to do.** Drop the `After` wrapper. Replace `Infinity` with the longest time the application accepts for one call. `config` is an `llm_wire.Config` and `classify_config` a `classify.Config`; each setter takes its own configuration.

```gleam
// 0.2
let generation =
  config |> llm_wire.with_call_timeout(llm_wire.After(duration.minutes(5)))
let classification =
  classify_config |> classify.with_timeout(llm_wire.Infinity)

// 0.3
let generation = config |> llm_wire.with_call_timeout(duration.minutes(5))
let classification =
  classify_config |> classify.with_timeout(duration.minutes(30))
```

An absolute deadline set on the HTTP Gun client view remains a ceiling for the call.

## `error.Status` carries the provider's code

**What changed.** `error.Status(code:, body:, retry_after:)` is now `error.Status(status:, code:, message:, body:, retry_after:)`. The HTTP status moved to the field `status`. `code` and `message` are the provider's own error code and message, read from the error body, each `None` when the body does not carry it:

- OpenAI: `error.code`, or `error.type` when the code is null, such as `"insufficient_quota"`.
- Anthropic: `error.type`, such as `"overloaded_error"`.
- Google: `error.status`, such as `"RESOURCE_EXHAUSTED"`.

Classification and transcription keep no error body, so their `Status` has `code: None` and `message: None`.

**Why.** OpenAI answers both an exhausted quota and a rate limit with 429, and only the provider's code tells them apart ([ADR 0023](https://github.com/gleam-dream/llm_wire/blob/main/docs/adr/0023-carry-the-provider-error-code-on-an-error-status.md)). The field `code` now means the provider's code here, as it does in `error.Provider(code, message)`.

**What to do.**

```gleam
// 0.2
case failure.error {
  error.Status(code: 429, ..) -> rate_limited()
  error.Status(code, body, _) -> other_status(code, body)
  _ -> other()
}

// 0.3
case failure.error {
  error.Status(code: Some("insufficient_quota"), ..) -> out_of_quota()
  error.Status(status: 429, ..) -> rate_limited()
  error.Status(status, _, _, body, _) -> other_status(status, body)
  _ -> other()
}
```

A value you construct, for example in a test, adds `code: None, message: None` or the provider's values.

`llm_wire.advise` now reads the provider's code before the status. A code that the table knows as permanent, such as OpenAI's `insufficient_quota` 429 or Anthropic's `invalid_request_error`, answers `WillNotHelpUnchanged`. `error.describe` adds the code to its line and never the message, because an authentication message can quote part of the key.

## An unknown stop reason is an outcome

**What changed.** `llm_wire.Outcome` has a new variant `UnrecognizedStop(reason:, partial_text:, partial_calls:, usage:)`, and `telemetry.Outcome` has `UnrecognizedStop` (`"unrecognized_stop"`). A stop reason that this version does not know now ends the call with `Ok(UnrecognizedStop(..))` instead of `Error(Failure(Provider(..)))`. This covers an OpenAI `response.incomplete` with a reason other than `max_output_tokens` and `content_filter`, a Gemini `OTHER`, and any unknown Anthropic or Gemini reason.

**Why.** Providers add stop reasons after a release. The text that arrived before an unknown reason is often usable, and only the application can decide whether it is an answer ([ADR 0022](https://github.com/gleam-dream/llm_wire/blob/main/docs/adr/0022-end-an-unrecognized-stop-reason-with-its-own-outcome.md)).

**What to do.** Add an arm wherever either type is matched without a catch-all. An application that trusts only known reasons treats it as `OutputLimited`:

```gleam
case llm_wire.run(client, prepared) {
  Ok(llm_wire.Answer(output:, ..)) -> Ok(output)
  Ok(llm_wire.NeedsTools(..)) -> run_tools()
  Ok(llm_wire.OutputLimited(..)) -> Error("output limit reached")
  Ok(llm_wire.Refused(reason:, ..)) -> Error(reason)
  Ok(llm_wire.UnrecognizedStop(reason:, ..)) ->
    Error("stopped for an unknown reason: " <> reason)
  Error(failure) -> Error(llm_wire.describe_failure(failure))
}
```

The calls in `partial_calls` are not admitted against the tool catalog; check them before acting on them. A custom adapter ends such a response with `provider.unrecognized_stop`.

## `ProviderExtension` is `UnrecognizedEvent`

**What changed.** `message.ProviderExtension(provider:, event_name:)` is now `message.UnrecognizedEvent(provider:, name:)`. It now also reports a block, delta or item type that LLM Wire does not know inside a known event, named by the event and the type, such as `content_block_start:future_block`. Such a type used to fail the call with a protocol error; now the call goes on.

**What to do.** Rename the constructor and the `event_name` label. A custom adapter that returned `ProviderExtension` returns `UnrecognizedEvent`.

```gleam
// 0.2
message.ProviderExtension(provider:, event_name:) -> log(provider, event_name)

// 0.3
message.UnrecognizedEvent(provider:, name:) -> log(provider, name)
```

An unknown Anthropic content block left open at `message_stop` is now a protocol failure, like any other open block.

## Thinking continues a tool round

**What changed.** `error.ThinkingInToolRound` is removed from `error.ThinkingProblem`: preparation no longer refuses a thinking level while an Anthropic tool round continues. An Anthropic `NeedsTools` turn now keeps its thinking blocks, redacted thinking blocks and content blocks of an unknown type in `provider_data`, and the next request sends them back unchanged and in their original order ([ADR 0024](https://github.com/gleam-dream/llm_wire/blob/main/docs/adr/0024-replay-anthropic-thinking-blocks-in-tool-rounds.md)).

**What to do.**

- Delete the `ThinkingInToolRound` arm.
- Append the returned `AssistantTurn` itself with `message.Assistant(turn)`, and store it with `message.turn_to_json` and `message.turn_decoder`. A turn rebuilt from its text and calls loses the thinking, and Anthropic then rejects or degrades the tool round.
- Replay data counts against `limit.ProviderMetadataBytes` (1 MiB by default). A turn with very long thinking can fail with `LimitExceeded(ProviderMetadataBytes)`; raise the limit with `llm_wire.with_limit` if that happens.

## Behaviour changes without a signature change

- **An owner failure no longer ends the process that created the stream.** Each call's owner process is monitored by its creator instead of linked to it. A custom reducer that raises, a crashed transport worker, or a `close` that kills an unresponsive owner now reaches the caller as a typed read error (`OwnerGone`, `StreamEnded`, or `Stopped` from `run` and `collect`), not as an exit signal. Code that trapped exits to survive this no longer needs to.
- **A reader that exits clears only its own read.** When a process other than the stream's creator exits while it waits in `next`, the call goes on and another holder of the handle can keep reading. Only the creator's exit ends the call.
- **Gemini tool arguments with large arrays or objects are read in time proportional to their size.** A single large argument event no longer holds the call's owner process, and with it the call's timers and `close`, for tens of seconds.
