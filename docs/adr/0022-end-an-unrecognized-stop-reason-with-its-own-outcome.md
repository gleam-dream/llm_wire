# End an unrecognized stop reason with its own outcome

<a id="adr-0022"></a>

## Decision and alternatives

- Providers add stop reasons without notice. A built-in reducer used to fail the call with `error.Provider(code: reason)` for any stop reason it did not know. The provider had finished a normal response and the tokens were spent, but the text was discarded, and `advise` gave no prospect, so a retry loop could pay for the same failure again. Anthropic's `stop_sequence` (fixed separately) and `model_context_window_exceeded`, and Gemini's `CONTINUATION` and `ESCALATION`, all reached callers this way.
- On 2026-11-25 the repository owner ruled that an unknown stop reason ends the call with an explicit outcome, so that the compiler makes every caller decide what an unknown reason means. `Outcome(o)` gains `UnrecognizedStop(reason, partial_text, partial_calls, usage)`. `reason` is the provider's own value, unchanged; the text and calls are what arrived before it. The calls are not admitted against the tool catalog and must not be dispatched as a normal tool batch. A custom adapter ends this way with `provider.unrecognized_stop`, and `testing.unrecognized_stop` scripts it on every wire.
- Known reasons map to the outcome they mean: Anthropic `model_context_window_exceeded` and Gemini `CONTINUATION` are output-limited; Gemini `ESCALATION` and `IMAGE_RECITATION` are content filters. A known reason that names a provider-side fault (Gemini's malformed or unexpected function call, tool loop, missing thought signature, malformed response) still fails: the library knows that reason, and it describes no answer. Gemini's own `OTHER` ("unknown reason") is an unrecognized stop. Anthropic `pause_turn` still fails, because the application cannot continue a hosted tool loop the library does not model.
- Rejected: treating an unknown reason as `Answer`. The library would assert a meaning it does not know; a new reason can as well mean a cut answer.
- Rejected: treating it as `OutputLimited`. It would hide that the reason is new and give the application no way to learn which reason arrived.
- Rejected: keeping the failure and adding the partial text to `Failure`. A failure with a complete answer inside it still reads as a failure to every retry policy, and the compiler would not ask callers to decide.
- The observation outcome set gains `UnrecognizedStop` (`"unrecognized_stop"`) for the same reason. Both public types are closed, so the change breaks exhaustive matches; the package is unpublished and the owner prefers the break.

## Evidence and limits

- `test/llm_wire_stop_reason_test.gleam` drives each built-in wire through `llm_wire.run`. Before the change, Anthropic `model_context_window_exceeded` failed with `Provider(Some("model_context_window_exceeded"), "Unsupported Anthropic stop reason: ...")` and Gemini `CONTINUATION` with `Provider(Some("CONTINUATION"), "Unknown Google finish reason: ...")`.
- The reason lists come from the providers' documentation as read on 2026-11-25: Anthropic's seven stop reasons, OpenAI's `incomplete_details.reason` values (`max_output_tokens`, `max_messages`, `content_filter`, `steered`) and Gemini's `FinishReason` enum. OpenAI's `max_messages` and `steered` are left as unrecognized stops: the documentation does not say whether the text before them is complete, and `steered` follows a WebSocket feature this library does not use.
- An unknown OpenAI response `status` still fails: it describes the response object, not why generation stopped, and no answer is known to be present.
