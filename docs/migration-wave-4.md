# Wave 4 migration

Wave 4 redesigns LLM Wire's public API (LLM-R1 to R11 of the release plan).
Every capability stays; the shape changes:

- one root module `llm_wire` for the common path, with one execution family
  for plain and structured output (`Request(o)`, `Prepared(o)`, `Stream(o)`,
  `Outcome(o)`);
- typed failures (`error.Error`, `error.PrepareError`, `limit.Limit`) and a
  `Failure` that carries the provider, submission evidence and usage;
  `error.Http` carries HTTP Gun's opaque `Failure`, not its `Reason`;
- `advise(failure)` without a provider argument, with a `Retry-After` delay;
- every timeout is a `gleam/time/duration.Duration`, with an explicit
  `Infinity`; three timers (whole call 600 s, first token 180 s, idle gap 60 s);
- callers build only opaque values; message, turn and tool-call records are
  returned values with JSON codecs;
- the plaintext rule moved to HTTP Gun's destination policy;
- telemetry carries a call id and the caller's correlation;
- `testing.events_for` fakes each built-in provider wire.

Add `gleam_time = ">= 1.11.0 and < 2.0.0"` to a dependent's `gleam.toml` when
it imports `gleam/time/duration`.

Contents: [modules](#modules) · [llm_wire](#llm_wire-formerly-session-config-retry) ·
[message](#llm_wiremessage-formerly-types) · [error](#llm_wireerror-formerly-typeswireerror) ·
[limit](#llm_wirelimit-formerly-typeslimits) · [tool](#llm_wiretool-formerly-types-tool-functions) ·
[providers](#llm_wireopenai-anthropic-google-formerly-providerconfig) ·
[provider](#llm_wireprovider) · [telemetry](#llm_wiretelemetry) ·
[testing](#llm_wiretesting) · [behavior](#behavior-changes) ·
[dependents](#dependents)

## Modules

| Before                                                        | After                                                                                                                                                                                |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `llm_wire/session`                                            | `llm_wire`                                                                                                                                                                           |
| `llm_wire/config`                                             | `llm_wire` (`Config` and setters), `llm_wire/openai`, `llm_wire/anthropic`, `llm_wire/google`, `llm_wire/provider.config`                                                            |
| `llm_wire/retry`                                              | `llm_wire.advise`                                                                                                                                                                    |
| `llm_wire/types`                                              | `llm_wire/message` (messages, turns, calls, usage, progress, provider), `llm_wire/error` (errors), `llm_wire/limit` (limits), `llm_wire/tool` (tools), `llm_wire` (request builders) |
| `llm_wire/provider/openai`, `/anthropic`, `/google`           | `llm_wire/openai`, `llm_wire/anthropic`, `llm_wire/google`                                                                                                                           |
| `llm_wire/provider`, `llm_wire/telemetry`, `llm_wire/testing` | same names, redesigned                                                                                                                                                               |

Gleam does not re-export constructors, so a type is matched from the module
that defines it: `message.User`, `error.Protocol`, `limit.EventBytes`,
`tool.UnknownTool`, `llm_wire.Answer`.

## `llm_wire` (formerly `session`, `config`, `retry`)

### Configuration

| Before                                                                                | After                                                                                                                      |
| ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `config.Config`                                                                       | `llm_wire.Config` (opaque)                                                                                                 |
| `config.openai(openai.options(key))`                                                  | `openai.new("sk-...") \|> openai.config`                                                                                   |
| `config.anthropic(anthropic.options(key))`                                            | `anthropic.new(key) \|> anthropic.config`                                                                                  |
| `config.google(google.options(key))`                                                  | `google.new(key) \|> google.config`                                                                                        |
| `config.from_provider(adapter)`                                                       | `provider.config(adapter)`                                                                                                 |
| `config.with_endpoint(config, types.Endpoint)`                                        | `llm_wire.with_endpoint(config, String)`; checked by `prepare`                                                             |
| `config.with_limits(config, types.Limits(..))`                                        | `llm_wire.with_limit(config, limit.Limit, Int)`, one call per changed limit                                                |
| `config.with_deadlines(config, types.Deadlines(overall, idle, read))`                 | `llm_wire.with_call_timeout(config, After(d))`, `with_first_token_timeout`, `with_idle_timeout`; `read_timeout_ms` is gone |
| `config.with_tool_call_checks(config, types.ReportInvalidToolCalls)`                  | `llm_wire.with_tool_call_checks(config, tool.ReportInvalidToolCalls)`                                                      |
| `config.adapter`, `limits`, `deadlines`, `tool_call_checks`, `validate` (`@internal`) | removed                                                                                                                    |
| —                                                                                     | `llm_wire.Bound { After(Duration) Infinity }`                                                                              |

```gleam
// Before
let assert Ok(key) = types.api_key("sk-...")
let assert Ok(endpoint) = types.endpoint("http://127.0.0.1:4000/v1")
let settings =
  config.openai(openai.options(key))
  |> config.with_endpoint(endpoint)
  |> config.with_deadlines(types.Deadlines(120_000, 30_000, 5000))
  |> config.with_limits(
    types.Limits(..types.default_limits(), total_text_bytes_limit: 8_388_608),
  )

// After
let config =
  openai.new("sk-...")
  |> openai.config
  |> llm_wire.with_endpoint("http://127.0.0.1:4000/v1")
  |> llm_wire.with_call_timeout(llm_wire.After(duration.seconds(120)))
  |> llm_wire.with_idle_timeout(llm_wire.After(duration.seconds(30)))
  |> llm_wire.with_limit(limit.TotalTextBytes, 8_388_608)
```

The old idle timer started before the request was sent and was the only bound
on the first token. Map an old `idle_timeout_ms` to `with_idle_timeout`, and set
`with_first_token_timeout` if the old value was chosen to bound the first token.

### Requests

| Before                                                                                         | After                                                                                         |
| ---------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `types.Request` (public record)                                                                | `llm_wire.Request(o)` (opaque); `o` is `String` or the `with_output` codec's type             |
| `types.new_request(model_id, messages)`                                                        | `llm_wire.request("model", messages)`                                                         |
| `types.with_tools`, `with_max_tokens`, `with_temperature`, `with_top_p`, `with_stop_sequences` | `llm_wire.with_tools` etc., same names                                                        |
| `types.with_prompt_cache(r, types.OpenAiPromptCacheKey(k))`                                    | `llm_wire.with_openai_prompt_cache_key(r, k)`                                                 |
| `types.with_prompt_cache(r, types.GoogleCachedContent(n))`                                     | `llm_wire.with_google_cached_content(r, n)`                                                   |
| `types.Request(..r, messages: m)`, `r.messages`                                                | `llm_wire.append(r, more)`, `llm_wire.messages(r)`                                            |
| `r.model`, `r.tools`, `r.max_tokens`                                                           | `llm_wire.model(r)`, `llm_wire.tools(r)`; read options from `llm_wire.request_json(prepared)` |
| `types.SystemMessage(t)` / `UserMessage(t)`                                                    | `llm_wire.system(t)` / `llm_wire.user(t)` (or `message.System`, `message.User`)               |
| `types.AssistantMessage(t)`                                                                    | `llm_wire.assistant(t)`                                                                       |
| `types.ToolResultMessage(call_id, c)`                                                          | `llm_wire.tool_result(call, c)` or `message.ToolResult("id", c)`                              |

### Execution

| Before                                                                                                                | After                                                                                                                             |
| --------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `session.PreparedCall`, `session.PreparedStructuredCall(o)`                                                           | `llm_wire.Prepared(o)`                                                                                                            |
| `session.prepare(settings, request) -> Result(_, WireError)`                                                          | `llm_wire.prepare(config, request) -> Result(Prepared(o), error.PrepareError)`                                                    |
| `session.prepare_structured(settings, request, name, codec)`                                                          | `llm_wire.prepare(config, request \|> llm_wire.with_output(name, codec))`                                                         |
| `session.run`, `run_structured`                                                                                       | `llm_wire.run(client, prepared) -> Result(Outcome(o), Failure)`                                                                   |
| `session.stream`, `stream_structured`                                                                                 | `llm_wire.stream(client, prepared) -> Result(Stream(o), Failure)`                                                                 |
| `session.next`, `next_structured`                                                                                     | `llm_wire.next(stream) -> Result(Event(o), ReadError)`; `llm_wire.next_within(stream, Duration)`                                  |
| `session.collect`, `collect_structured`                                                                               | `llm_wire.collect(stream)`                                                                                                        |
| `session.close`, `close_structured`                                                                                   | `llm_wire.close(stream) -> CloseOutcome`                                                                                          |
| `session.prepared_request_json`, `structured_request_json`                                                            | `llm_wire.request_json(prepared)`                                                                                                 |
| `session.prepared_provider(prepared)`                                                                                 | `failure.provider`, `turn.provider`                                                                                               |
| `session.RunResult`, `StructuredRunResult(o)`                                                                         | `llm_wire.Outcome(o)`                                                                                                             |
| `RunText(text, usage)`, `StructuredValue(value, raw_json, usage)`                                                     | `Answer(output: o, text: String, usage:)`                                                                                         |
| `RunToolCalls(turn, usage)`, `StructuredNeedsTools(turn, usage)`                                                      | `NeedsTools(turn:, issues:, usage:)`; `issues` moved here from the turn                                                           |
| `RunOutputLimited(..)`, `StructuredOutputLimited(..)`                                                                 | `OutputLimited(partial_text:, partial_calls:, usage:)`                                                                            |
| `RunRefusal(reason, usage)`, `StructuredRefusal(..)`                                                                  | `Refused(reason:, usage:)`                                                                                                        |
| `session.RunFailure(error, retry)`                                                                                    | `llm_wire.Failure(error:, sent:, partial_output:, provider:, usage:)`                                                             |
| `session.ReadResult`: `NextProgress(p)`, `StreamTerminal(t)`                                                          | `llm_wire.Event(o)`: `Progress(p)`, `Done(Result(Outcome(o), Failure))`                                                           |
| `session.Terminal`: `Finished(r)`, `Failed(e, ev)`, `Cancelled(ev)`                                                   | `Done(Ok(r))`, `Done(Error(Failure(..)))`, `Done(Error(Failure(error: error.Cancelled, ..)))`                                     |
| `session.ReadError`: `StreamReadError(types.ReadError)`, `TerminalConversionError(e)`                                 | `llm_wire.ReadError`: `StreamEnded`, `ConcurrentRead`, `OwnerGone`, `TimedOut`; a conversion failure is now a `Failure` in `Done` |
| `types.ReadError`: `StreamClosed`, `ConcurrentReadConflict`, `OwnerUnavailable`, `ReadTimeout`                        | `StreamEnded`, `ConcurrentRead`, `OwnerGone`, `TimedOut`                                                                          |
| `types.CloseOutcome`: `ConsumerClosed`, `ProviderCancellationConfirmed`, `AlreadyTerminal`; `close` returned `Result` | `llm_wire.CloseOutcome`: `Closed`, `AlreadyEnded`; `close` never fails                                                            |
| `types.RetryEvidence(classification, response_bytes_observed, semantic_progress_observed)`                            | `failure.sent` and `failure.partial_output`                                                                                       |
| `types.NoRequestSent`, `RequestMayHaveReachedProvider`, `EffectUnknown`                                               | `llm_wire.NotSent`, `MaybeSent`, `MaybeSent`; a finished response that failed is `Completed`                                      |
| `session.fixture_exchange`, `structured_fixture_exchange` (`@internal`)                                               | removed; `testing.exchange`                                                                                                       |

```gleam
// Before
let assert Ok(prepared) = session.prepare_structured(settings, request, "invoice", codec)
case session.run_structured(client, prepared) {
  Ok(session.StructuredValue(value:, ..)) -> Ok(value)
  Ok(session.StructuredRefusal(reason:, ..)) -> Error(reason)
  Ok(_) -> Error("no value")
  Error(session.RunFailure(error:, retry:)) -> Error(string.inspect(error))
}

// After
let assert Ok(prepared) =
  llm_wire.prepare(config, request |> llm_wire.with_output("invoice", codec))
case llm_wire.run(client, prepared) {
  Ok(llm_wire.Answer(output:, ..)) -> Ok(output)
  Ok(llm_wire.Refused(reason:, ..)) -> Error(reason)
  Ok(_) -> Error("no value")
  Error(failure) -> Error(llm_wire.describe_failure(failure))
}
```

```gleam
// Before: streaming polled every 5 s
case session.next(stream) {
  Ok(session.NextProgress(types.TextDelta(_, text))) -> show(text)
  Ok(session.StreamTerminal(session.Finished(result))) -> done(result)
  Error(session.StreamReadError(types.ReadTimeout)) -> keep_waiting()
  _ -> fail()
}

// After: next waits, bounded by the call's timers
case llm_wire.next(stream) {
  Ok(llm_wire.Progress(message.TextDelta(text:, ..))) -> show(text)
  Ok(llm_wire.Progress(_)) -> Nil
  Ok(llm_wire.Done(result)) -> done(result)
  Error(_) -> fail()
}
```

### Retry advice

| Before                                                             | After                                                                                                                                                                                     |
| ------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `retry.assess(provider, error) -> RetryProspect`                   | `llm_wire.advise(failure) -> RetryAdvice(prospect:, after: Option(Duration))`                                                                                                             |
| `retry.MayHelp`, `WillNotHelpUnchanged`, `Unknown`                 | `llm_wire.MayHelp`, `WillNotHelpUnchanged`, `Unknown`                                                                                                                                     |
| `HttpFailure(_)` assessed as `Unknown`                             | classified by HTTP Gun `Kind`: `Unavailable`, `Network`, `TimedOut` → `MayHelp`; `InvalidInput`, `Refused`, `TooLarge`, `CancelledLocally`, `Misuse`, `Playback` → `WillNotHelpUnchanged` |
| `RetryHint`: `RetryDelaySeconds(n)`, `RetryHeaderValue(http_date)` | `after`: seconds or an HTTP date converted to a `Duration` on receipt, from `error.Status.retry_after` or the HTTP Gun failure's `headers`                                                |
| `OutputValidationError` assessed as `Unknown`                      | `InvalidOutput` stays `Unknown`                                                                                                                                                           |
| —                                                                  | `llm_wire.describe_failure(failure)`                                                                                                                                                      |

```gleam
// Before: extractor rebuilt a Failure to reach Kind
case retry.assess(provider, error) { retry.MayHelp -> retry_later() _ -> give_up() }

// After
case llm_wire.advise(failure) {
  llm_wire.RetryAdvice(llm_wire.MayHelp, after:) -> snooze(option.unwrap(after, default))
  _ -> give_up(llm_wire.describe_failure(failure))
}
```

## `llm_wire/message` (formerly `types`)

| Before (`types`)                                                                                    | After (`message`)                                                                                                                        |
| --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `Provider`: `OpenAI`, `Anthropic`, `Google`, `Custom(name)`                                         | same variants in `message`                                                                                                               |
| `Content`: `TextContent`, `ImageUrlContent`, `InlineImageContent`                                   | `TextPart`, `ImageUrlPart`, `InlineImagePart`                                                                                            |
| `Message`: `SystemMessage(content)`                                                                 | `System(text)`                                                                                                                           |
| `UserMessage(content)`                                                                              | `User(text)`                                                                                                                             |
| `UserContent(parts)`                                                                                | `UserParts(parts)`                                                                                                                       |
| `AssistantMessage(content)`                                                                         | `Assistant(AssistantTurn(provider: None, text:, calls: [], response_id: None, provider_data: None))` (`llm_wire.assistant(text)`)        |
| `AssistantContent(parts)`                                                                           | `AssistantParts(parts)`                                                                                                                  |
| `AssistantToolCalls(calls)`, `AssistantToolCallsWithText(text, calls)`                              | `Assistant(AssistantTurn(provider: None, text:, calls:, response_id: None, provider_data: None))`                                        |
| `AssistantTurnMessage(turn)`                                                                        | `Assistant(turn)`                                                                                                                        |
| `ToolResultMessage(call_id: CallId, content)`                                                       | `ToolResult(call_id: String, content)`                                                                                                   |
| `AssistantTurn(provider, text, calls, response_id, provider_data, issues)`                          | `AssistantTurn(provider: Option(Provider), text, calls, response_id, provider_data)`; `issues` moved to `llm_wire.NeedsTools`            |
| `ToolCall(id: CallId, name: ToolName, arguments_json, provider_id, provider_state)`                 | `ToolCall(id: String, name: String, arguments_json, provider_id, provider_state)`                                                        |
| `tool_call(CallId, ToolName, args)`                                                                 | `message.tool_call(String, String, args)`                                                                                                |
| `ModelId`, `model_id`, `model_id_to_string`                                                         | plain `String`; empty fails `prepare` with `InvalidSetting(Model, _)`                                                                    |
| `CallId`, `call_id`, `call_id_to_string`                                                            | plain `String`                                                                                                                           |
| `ToolName`, `tool_name`, `tool_name_to_string`, `ToolNameError`                                     | plain `String`; `tool.check_name(name) -> Result(Nil, tool.NameProblem)`                                                                 |
| `ApiKey`, `api_key`, `reveal_api_key`                                                               | `openai.new(String)` etc.; the key is never revealed                                                                                     |
| `Endpoint`, `endpoint`, `endpoint_to_string`                                                        | `llm_wire.with_endpoint(config, String)`                                                                                                 |
| `ToolResult(call_id, content)` (unused record)                                                      | removed                                                                                                                                  |
| `Usage(input_tokens, output_tokens, total_tokens)`                                                  | `message.Usage`, same fields                                                                                                             |
| `StreamProgress`: `TextDelta`, `RefusalDelta`, `ReasoningDelta`, `ProviderExtension`, `UsageUpdate` | `message.Progress`, same variants plus `ToolArgumentsDelta(call_id, text)`                                                               |
| `PromptCache`: `OpenAiPromptCacheKey`, `GoogleCachedContent`                                        | `llm_wire.with_openai_prompt_cache_key`, `with_google_cached_content`; adapters read `provider.PromptCache`                              |
| —                                                                                                   | `message.provider_name`, `to_json`, `decoder`, `turn_to_json`, `turn_decoder`, `turn_replay_to_json`, `turn_replay_decoder(text, calls)` |

```gleam
// Before
types.new_request(model, [
  types.SystemMessage("Be brief"),
  types.UserMessage("Weather?"),
  types.AssistantToolCalls([types.tool_call(id, name, "{}")]),
  types.ToolResultMessage(id, "sunny"),
])

// After
llm_wire.request("gpt-5", [
  llm_wire.system("Be brief"),
  llm_wire.user("Weather?"),
  message.Assistant(message.AssistantTurn(
    provider: None,
    text: "",
    calls: [message.tool_call("call_1", "weather", "{}")],
    response_id: None,
    provider_data: None,
  )),
  message.ToolResult("call_1", "sunny"),
])
```

### Stored turns (Fabric's `llm_wire.turn.v1`)

`message.turn_replay_to_json` writes exactly the fields Fabric stores under
`ProviderData("llm_wire.turn.v1", data)`: `provider` (`{"kind", "name"}`),
`response_id` and `provider_data`. `message.turn_replay_decoder(text, calls)`
reads that data, including records Fabric wrote before this wave, whose
`issues` list it ignores, and completes the turn with the text and calls Fabric
keeps itself. The full `turn_to_json` adds `format: "llm_wire.turn.v1"`, `text`
and `calls` to the same fields; its decoder fails on another format tag.

```gleam
// Before (fabric/llm.gleam): a 120-line private envelope
// After
let data = json.to_string(message.turn_replay_to_json(turn))
model.AssistantTurn(turn.text, calls, Some(model.ProviderData("llm_wire.turn.v1", data)))
// and on restore
json.parse(data, message.turn_replay_decoder(stored.text, wire_calls))
```

## `llm_wire/error` (formerly `types.WireError`)

`WireError` splits into `error.Error` (execution) and `error.PrepareError`
(pure preparation, which never describes the network).

| Before `WireError`                                                       | After                                                                                                                                                                |
| ------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ConfigurationError(reason)`                                             | `PrepareError.InvalidSetting(setting: Setting, reason)`; at execution `error.Stopped`                                                                                |
| `PreparationError(reason)`                                               | `PrepareError.InvalidRequest(problem: RequestProblem)`, `UnsupportedSchema(location: SchemaLocation, reason)`, `ToolResultMismatch(call_id, problem: ResultProblem)` |
| `TransportError(reason)`                                                 | `error.Stopped` (owner gone, stream closed before a result)                                                                                                          |
| `HttpFailure(reason: http_error.Reason)`                                 | `Http(failure: http_error.Failure)`; read the reason with `http_error.reason(failure)`                                                                               |
| `HttpStatusError(status_code, body, retry_hint)`                         | `Status(code, body, retry_after: Option(Duration))`                                                                                                                  |
| `ProviderError(code, message)`                                           | `Provider(code, message)`                                                                                                                                            |
| `ProtocolError(reason)`                                                  | `Protocol(detail)`                                                                                                                                                   |
| `ResourceLimitExceeded(limit_name: String, limit_value, measured_value)` | `LimitExceeded(limit: limit.Limit, limit_value, measured)`; before sending, `PrepareError.RequestTooLarge(limit, limit_value, measured)`                             |
| `DeadlineExceeded(OverallDeadline)`                                      | `DeadlineExceeded(WholeCall)`                                                                                                                                        |
| `DeadlineExceeded(IdleDeadline)`                                         | `DeadlineExceeded(FirstToken)` before the first progress event, `DeadlineExceeded(IdleGap)` after                                                                    |
| `DeadlineExceeded(ReadDeadline)`                                         | removed; `next_within` returns `TimedOut`                                                                                                                            |
| `CancelledLocally`                                                       | `Cancelled`                                                                                                                                                          |
| `OutputValidationError(reason)`                                          | `InvalidOutput(raw_output, failure: ValueFailure)`; `ValueFailure`: `InvalidJson(ParseError)`, `SchemaRejected(ValidationError)`, `DecodeRejected(DecodeError)`      |
| `DeadlineType`                                                           | `error.Timeout`: `WholeCall`, `FirstToken`, `IdleGap`                                                                                                                |
| `RetryHint`                                                              | `Status.retry_after`                                                                                                                                                 |
| —                                                                        | `error.describe`, `error.name`, `error.timeout_name`, `error.describe_value_failure`, `error.describe_prepare_error`                                                 |

| Old preparation string                                                                                                                                                                                                                 | `PrepareError`                                                                                                    |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `model_id cannot be empty`                                                                                                                                                                                                             | `InvalidSetting(Model, _)`                                                                                        |
| `api_key cannot be empty`                                                                                                                                                                                                              | `InvalidSetting(ApiKey, _)`                                                                                       |
| `endpoint must start with …`, `Endpoint authority or path is invalid`, `Endpoint must use HTTPS …`                                                                                                                                     | `InvalidSetting(Endpoint, _)`; plaintext to a remote host is no longer a preparation error (see behavior changes) |
| `all limits must be positive`                                                                                                                                                                                                          | `InvalidSetting(LimitSetting(limit), _)`                                                                          |
| `all deadline timeouts must be positive`                                                                                                                                                                                               | `InvalidSetting(TimeoutSetting(timeout), _)`                                                                      |
| `Invalid provider header`                                                                                                                                                                                                              | `InvalidSetting(Header, _)`                                                                                       |
| `Structured output name cannot be empty`                                                                                                                                                                                               | `InvalidSetting(OutputName, _)`                                                                                   |
| `max_tokens must be positive`                                                                                                                                                                                                          | `InvalidRequest(MaxTokensNotPositive)`                                                                            |
| `temperature must be between 0 and 2`                                                                                                                                                                                                  | `InvalidRequest(TemperatureOutOfRange)`                                                                           |
| `top_p must be between 0 and 1`                                                                                                                                                                                                        | `InvalidRequest(TopPOutOfRange)`                                                                                  |
| `OpenAI prompt_cache_key cannot be empty`, `Google cachedContent cannot be empty`                                                                                                                                                      | `InvalidRequest(EmptyPromptCache)`                                                                                |
| `… cannot be used with the … profile`, `prompt caching is not admitted by the Anthropic profile`                                                                                                                                       | `InvalidRequest(PromptCacheUnsupported)`                                                                          |
| `stop_sequences are not supported by the Responses profile`                                                                                                                                                                            | `InvalidRequest(StopSequencesUnsupported)`                                                                        |
| `Google GenerationConfig.stopSequences accepts at most 5 values`                                                                                                                                                                       | `InvalidRequest(TooManyStopSequences(5))`                                                                         |
| `… image URLs …`                                                                                                                                                                                                                       | `InvalidRequest(ImageUrlUnsupported)`                                                                             |
| `Duplicate tool name: x`                                                                                                                                                                                                               | `InvalidRequest(DuplicateToolName("x"))`                                                                          |
| `Duplicate tool call ID`, empty call id in history                                                                                                                                                                                     | `InvalidRequest(InvalidCallId(id))`                                                                               |
| invalid tool name in history                                                                                                                                                                                                           | `InvalidRequest(InvalidToolName(name))`                                                                           |
| `Assistant turn belongs to a different provider`                                                                                                                                                                                       | `InvalidRequest(TurnFromOtherProvider)`                                                                           |
| `This provider does not accept opaque assistant data`, `Google assistant turn is missing provider data`, `Invalid Google assistant data`, `Google … nesting exceeds 64`, `Google part is not an object`, `Google raw parts disagree …` | `InvalidRequest(InvalidProviderData(reason))`                                                                     |
| `Unknown tool result: x`                                                                                                                                                                                                               | `ToolResultMismatch("x", UnknownCall)`                                                                            |
| `Duplicate tool result: x`                                                                                                                                                                                                             | `ToolResultMismatch("x", DuplicateResult)`                                                                        |
| `Missing tool result: x`                                                                                                                                                                                                               | `ToolResultMismatch("x", MissingResult)`                                                                          |
| `Tool result has no preceding assistant calls`                                                                                                                                                                                         | `ToolResultMismatch(id, NoPrecedingCalls)`                                                                        |
| `Tool schema uses a Blueprint variant …`, `Number schema bound …`                                                                                                                                                                      | `UnsupportedSchema(ToolInput(name), reason)`                                                                      |
| `Structured output requires …`, `Structured output codec has no schema`, `… cannot be admitted`                                                                                                                                        | `UnsupportedSchema(Output, reason)`                                                                               |
| `ResourceLimitExceeded("request_bytes_limit", ..)` and other limits in history                                                                                                                                                         | `RequestTooLarge(limit.RequestBytes, ..)` etc.                                                                    |

```gleam
// Before (extractor/outcome.gleam)
case error {
  types.ResourceLimitExceeded(limit_name: "total_text_bytes_limit", ..) -> discard()
  types.OutputValidationError(reason) ->
    case string.starts_with(reason, "Structured output failed schema") { .. }
  types.HttpFailure(reason) ->
    http_error.is_retryable(http_error.new(reason, submission(evidence)), idempotent: True)
  _ -> ..
}

// After
case failure.error {
  error.LimitExceeded(limit: limit.TotalTextBytes, ..) -> discard()
  error.InvalidOutput(raw_output:, failure: error.SchemaRejected(_)) -> reject(raw_output)
  error.Http(http_failure) -> http_error.is_retryable(http_failure, idempotent: True)
  _ -> ..
}
```

## `llm_wire/limit` (formerly `types.Limits`)

| Before `Limits` field                                                                          | After `limit.Limit`                                                           |
| ---------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| `request_bytes_limit`                                                                          | `RequestBytes`                                                                |
| `chunk_bytes_limit`                                                                            | `ChunkBytes`                                                                  |
| `line_bytes_limit`                                                                             | `LineBytes`                                                                   |
| `event_bytes_limit`                                                                            | `EventBytes`                                                                  |
| `response_body_bytes_limit`                                                                    | `ResponseBodyBytes`                                                           |
| — (was `min(64 KiB, response_body_bytes_limit)`, reported as `error_body_bytes_limit`)         | `ErrorBodyBytes`, default 64 KiB                                              |
| `queue_count_limit` (also bounded events per chunk)                                            | `QueueCount`                                                                  |
| `queue_bytes_limit`                                                                            | `QueueBytes`                                                                  |
| `active_blocks_limit`                                                                          | `ActiveBlocks`                                                                |
| `text_bytes_per_block_limit`                                                                   | `TextBytesPerBlock`                                                           |
| `total_text_bytes_limit`                                                                       | `TotalTextBytes`                                                              |
| `argument_bytes_per_call_limit`                                                                | `ArgumentBytesPerCall`                                                        |
| `total_argument_bytes_limit`                                                                   | `TotalArgumentBytes`                                                          |
| `provider_metadata_bytes_limit`                                                                | `ProviderMetadataBytes`                                                       |
| `extension_bytes_limit`                                                                        | `ExtensionBytes`                                                              |
| `types.default_limits()`                                                                       | `limit.default(limit)`; `limit.all()`, `limit.name(limit)`                    |
| `types.Deadlines(overall_timeout_ms, idle_timeout_ms, read_timeout_ms)`, `default_deadlines()` | `llm_wire.with_call_timeout`, `with_first_token_timeout`, `with_idle_timeout` |

## `llm_wire/tool` (formerly `types` tool functions)

| Before                                                                                   | After                                                                                                                                     |
| ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `types.ToolDefinition`                                                                   | `tool.Tool` (opaque)                                                                                                                      |
| `types.tool_from_codec(ToolName, description, codec) -> Result(_, WireError)`            | `tool.new("name", description, codec) -> Tool`; panics, naming the tool, on a definition bug                                              |
| `types.tool_from_contract(ToolName, description, contract) -> ToolDefinition`            | `tool.from_contract("name", description, contract) -> Result(Tool, ToolError)`                                                            |
| —                                                                                        | `tool.from_json_schema("name", description, json) -> Result(Tool, ToolError)` (an MCP `inputSchema`; `$schema` defaults to Draft 2020-12) |
| `types.tool_name_of`, `tool_description`, `tool_schema`                                  | `tool.name`, `tool.description`, `tool.schema`                                                                                            |
| `types.ToolNameError`: `EmptyToolName`, `InvalidToolNameCharacter`, `ToolNameTooLong`    | `tool.NameProblem`: `EmptyName`, `InvalidCharacter`, `NameTooLong`; `tool.check_name`                                                     |
| `types.ToolCallChecks`: `RejectInvalidToolCalls`, `ReportInvalidToolCalls`               | `tool.ToolCallChecks`, same variants                                                                                                      |
| `types.ToolCallIssue`: `UnknownTool(CallId)`, `InvalidArguments(CallId, reason: String)` | `tool.UnknownTool(call_id: String)`, `tool.InvalidArguments(call_id: String, failure: error.ValueFailure)`                                |
| re-decoding `call.arguments_json`                                                        | `tool.decode_arguments(call, codec) -> Result(a, ValueFailure)`                                                                           |
| —                                                                                        | `tool.describe_issue(issue)`, `tool.describe_error(error)`                                                                                |

```gleam
// Before
let assert Ok(name) = types.tool_name("lookup")
let assert Ok(lookup) = types.tool_from_codec(name, "Lookup", input_codec)
let assert Ok(contract) = contract.from_schema(spec.schema)
let mcp = types.tool_from_contract(name, "From MCP", contract)

// After
let lookup = tool.new("lookup", "Lookup", input_codec)
let assert Ok(mcp) = tool.from_contract("lookup", "From MCP", contract)
let assert Ok(mcp) = tool.from_json_schema("lookup", "From MCP", input_schema_json)
```

## `llm_wire/openai`, `anthropic`, `google` (formerly `provider/*` + `config`)

| Before                                                | After                                    |
| ----------------------------------------------------- | ---------------------------------------- |
| `provider/openai.options(ApiKey)`                     | `openai.new(String)`                     |
| `openai.with_organization`, `with_project`            | unchanged                                |
| `provider/anthropic.options(ApiKey)`, `with_version`  | `anthropic.new(String)`, `with_version`  |
| `provider/google.options(ApiKey)`, `with_api_version` | `google.new(String)`, `with_api_version` |
| `values(options)` (`@internal`)                       | removed                                  |
| `config.openai(options)` etc.                         | `openai.config(options)` etc.            |

## `llm_wire/provider`

| Before                                                                                                                                                                   | After                                                                                                                                            |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `provider.Spec(identity:, endpoint:, headers:, encode:, project_tool_schema:, project_output_schema:, new_reducer:)` + `provider.adapter(spec)`                          | `provider.new(provider, endpoint: String, encode, fn() -> Reducer)` \|> `with_headers(fn)` \|> `with_tool_schema(f)` \|> `with_output_schema(f)` |
| `encode: fn(types.Request, List(ProjectedTool), Option(OutputFormat)) -> Result(EncodedRequest, WireError)`                                                              | `fn(provider.Request, List(ProjectedTool), Option(OutputFormat)) -> Result(provider.Encoded, error.PrepareError)`                                |
| `EncodedRequest(path, body)`                                                                                                                                             | `provider.encoded(path, body)`                                                                                                                   |
| `project_*_schema: fn(Schema) -> Result(Json, WireError)`                                                                                                                | `fn(Schema) -> Result(Json, String)`; the runtime wraps the reason in `UnsupportedSchema`                                                        |
| `new_reducer: fn(Limits, List(ToolDefinition)) -> Result(Reducer, WireError)`                                                                                            | `fn() -> Reducer`; cannot fail                                                                                                                   |
| `provider.reducer(state, step, terminal, retry)`                                                                                                                         | `provider.reducer(state, step, terminal)`; no retry callback                                                                                     |
| `step: fn(state, provider.Event) -> Result(#(state, List(StreamProgress)), WireError)`                                                                                   | `fn(state, provider.Event) -> Result(#(state, List(message.Progress)), error.Error)`                                                             |
| `provider.Event(event, data, id, retry)`                                                                                                                                 | `provider.Event`, same fields (read by label); `provider.event(name, data)` builds one                                                           |
| `Terminal`: `Text`, `ToolCalls`, `OutputLimited`, `Refusal`, `Failure(error, retry)`, `Cancellation(retry)`                                                              | `provider.text`, `tool_calls`, `output_limited`, `refused`, `failed(error, usage)`; cancellation removed                                         |
| `ProjectedTool(name: ToolName, ..)`, `OutputFormat(name, schema)`                                                                                                        | same records, `name: String`; read fields by label                                                                                               |
| `provider.blueprint_schema`                                                                                                                                              | unchanged, returns `Result(Json, String)`                                                                                                        |
| `identity`, `endpoint`, `reveal_headers`, `with_endpoint`, `encode`, `project_tool_schema`, `project_output_schema`, `new_reducer`, `step`, `terminal`, `retry_evidence` | removed, except `step(reducer, event)` and `terminal(reducer)` for testing a reducer; `llm_wire.with_endpoint` on the config                     |
| `config.from_provider(adapter)`                                                                                                                                          | `provider.config(adapter)`                                                                                                                       |

```gleam
// Before
let adapter =
  provider.adapter(provider.Spec(
    identity: types.Custom("acme"),
    endpoint: endpoint,
    headers: fn() { [#("authorization", "Bearer " <> types.reveal_api_key(key))] },
    encode: encode,
    project_tool_schema: provider.blueprint_schema,
    project_output_schema: provider.blueprint_schema,
    new_reducer: fn(_limits, _tools) { Ok(provider.reducer(initial, step, terminal, retry)) },
  ))
let settings = config.from_provider(adapter)

// After
let config =
  provider.new(message.Custom("acme"), "https://llm.acme.test/v1", encode, fn() {
    provider.reducer(initial, step, terminal)
  })
  |> provider.with_headers(fn() { [#("authorization", "Bearer " <> key)] })
  |> provider.config
```

## `llm_wire/telemetry`

| Before                                                                                              | After                                                                                                                                       |
| --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `telemetry.observation_event()`                                                                     | `telemetry.event()`, same event name `[llm_wire, observation]`                                                                              |
| `Metadata(stage: String, provider: String, outcome: String)`                                        | `Metadata(call: String, correlation: Option(Correlation), stage: Stage, provider: String, outcome: Outcome)`                                |
| `Stage`: `Prepared`, `RequestSent`, `FirstProgress`, `Terminal`, `Cancelled`, `Deadline`, `Cleanup` | `Started` replaces `Prepared` (emitted when execution starts: `prepare` emits nothing); the rest unchanged                                  |
| outcome strings                                                                                     | `telemetry.Outcome`; `outcome_name` gives the same strings, except deadlines `overall` → `whole_call`, `idle` → `first_token` or `idle_gap` |
| —                                                                                                   | `stage_name`, `outcome_name`                                                                                                                |

LLM Wire reads the correlation from the `http_gun.Client` view it is given
(`http_gun.correlation`), so a caller sets it once, on that view; there is no
LLM Wire-level setter.

```gleam
// After: one correlation for both packages' events
llm_wire.run(http_gun.with_correlation(client, correlation.from_key(job_id)), prepared)
```

```gleam
// Before
sinal.observe(llm_telemetry.observation_event(), fn(_, meta) {
  record(meta.stage, meta.provider, meta.outcome)
})

// After
sinal.observe(telemetry.event(), fn(_, meta) {
  record(meta.call, meta.correlation, telemetry.stage_name(meta.stage), meta.provider)
})
```

## `llm_wire/testing`

| Before                                                                                                                      | After                                                                                                                        |
| --------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `Reply`: `Events`, `Interrupted`, `Status`; `ScriptedCall`; `text`, `tool_calls`, `refusal`, `output_limited`, `with_usage` | unchanged (`with_usage` takes `message.Usage`)                                                                               |
| `exchange(session.PreparedCall, reply)`                                                                                     | `exchange(llm_wire.Prepared(o), reply)` for every output type                                                                |
| `structured_exchange`                                                                                                       | removed; `exchange`                                                                                                          |
| `http_reply(reply)`                                                                                                         | private                                                                                                                      |
| `config()`                                                                                                                  | unchanged (`Custom("scripted")`); its tool calls now emit `ToolArgumentsDelta`                                               |
| —                                                                                                                           | `events_for(provider, reply)`: lowers a scripted reply into OpenAI, Anthropic or Gemini SSE; `Status` and `Custom` unchanged |

```gleam
// Before (support_desk, ~100 lines of OpenAI SSE builders)
fake_provider.start([testing.Events([text("msg_1", "Hello") <> completed("r", 1, 1)])])

// After
fake_provider.start([testing.events_for(message.OpenAI, testing.text("Hello"))])
```

## Behavior changes

- **Timers (R1).** Whole call 600 s (was 60 s), first token 180 s from the
  start of execution to the first progress event (was the 15 s idle timer),
  idle gap 60 s between provider events after the first progress event (was
  15 s, reset only by text, refusal, reasoning or usage). Every provider event
  now resets the idle gap, including tool-argument deltas and pings. `next`
  waits for an event instead of returning `ReadTimeout` every 5 s.
- **Tool-argument progress.** OpenAI `function_call_arguments.delta`,
  Anthropic `input_json_delta` and Gemini function calls emit
  `message.ToolArgumentsDelta`.
- **Plaintext (R10).** `prepare` no longer refuses `http://` for hosts other
  than `localhost` and `127.0.0.1`, and `http://[::1]:port` parses. Each
  plaintext call's HTTP Gun view gets `destination.with_plaintext(
PlaintextToLoopbackOnly)`: plaintext to a resolved non-loopback address fails
  before sending with `error.Http(f)`, `http_error.reason(f) ==
DestinationRejected(PlaintextRefused(class))`, `sent: NotSent`. That view
  also satisfies a client's `config.require_view_destination`; the client's
  own destination policy still applies to every call.
- **Invalid structured output (R4)** fails the call with `sent: Completed`
  (was `EffectUnknown`), keeping the raw text and usage.
- **Usage on failure.** `failure.usage` keeps the last usage reported.
- **`prepare` is pure.** The `prepared` telemetry stage moved to execution as
  `started`.
- **Status bodies.** A non-200 body is kept up to `limit.ErrorBodyBytes`
  (64 KiB) independently of the response body limit.
- **Close.** `close` kills an owner that does not answer within 5 s instead of
  returning `ReadTimeout`.

## Dependents

Every public module of the previous API is removed or renamed, so every
dependent that imports LLM Wire stops compiling until migrated. Counts are uses
of each symbol. "(t)" marks test code.

### fabric (`/code/gleam-dream/fabric`) — heavy

`src/fabric/llm.gleam` (imports `config`, `retry`, `session`, `types`):

| Old symbols                                                                                                                                                          | Migration                                                                                                                                                                     |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `config.Config` x2, `config.with_tool_call_checks` x1, `types.ReportInvalidToolCalls` x1                                                                             | `llm_wire.Config`, `llm_wire.with_tool_call_checks(_, tool.ReportInvalidToolCalls)`                                                                                           |
| `retry.assess` x1, `retry.MayHelp`, `WillNotHelpUnchanged`, `Unknown`                                                                                                | `llm_wire.advise(failure).prospect`                                                                                                                                           |
| `session.prepare`, `session.run`, `session.prepared_provider`                                                                                                        | `llm_wire.prepare`, `llm_wire.run`, `failure.provider`                                                                                                                        |
| `session.RunText`, `RunToolCalls`, `RunOutputLimited`, `RunRefusal`, `RunFailure(error, evidence)`                                                                   | `llm_wire.Answer`, `NeedsTools`, `OutputLimited`, `Refused`, `Failure`                                                                                                        |
| `types.ModelId` x2, `new_request`, `with_tools`                                                                                                                      | `String`, `llm_wire.request`, `llm_wire.with_tools`                                                                                                                           |
| `types.ToolDefinition`, `tool_name` x2, `tool_from_contract`, `ToolNameError`                                                                                        | `tool.Tool`, `tool.check_name`, `tool.from_contract` (returns `Result`), `tool.NameProblem` / `tool.ToolError`                                                                |
| `types.Message`, `SystemMessage`, `UserMessage`, `AssistantMessage`, `AssistantToolCalls`, `AssistantToolCallsWithText`, `AssistantTurnMessage`, `ToolResultMessage` | `message.System`, `User`, `Assistant(..)`, `ToolResult`                                                                                                                       |
| `types.ToolCall` (labelled construction), `call_id` x3, `call_id_to_string` x2, `tool_name_to_string`                                                                | `message.ToolCall` with `String` ids and names                                                                                                                                |
| `types.Usage`, `Provider` and its variants, `WireError`, `HttpStatusError(status_code:, ..)`, `RetryEvidence`                                                        | `message.Usage`, `message.Provider`, `error.Error`, `error.Status(code:, ..)`, `failure.sent`                                                                                 |
| `types.AssistantTurn` (positional, 6 fields), `ToolCallIssue`, `UnknownTool`, `InvalidArguments`                                                                     | `message.AssistantTurn` (5 fields, `provider: Option(Provider)`); issues come from `NeedsTools.issues` as `tool.UnknownTool` / `tool.InvalidArguments(call_id, ValueFailure)` |
| private `llm_wire.turn.v1` envelope (L210-324)                                                                                                                       | `message.turn_replay_to_json` / `turn_replay_decoder(text, calls)`, same stored format; the `issues` list is no longer written (it is read and ignored)                       |
| `describe` with `string.inspect`                                                                                                                                     | `llm_wire.describe_failure`, `error.describe_prepare_error`                                                                                                                   |

`src/fabric/graph/llm.gleam` (imports `config`, `session`, `types`):
`session.prepare_structured`, `run_structured`, `StructuredValue(value, raw, usage)`,
`StructuredRefusal`, `StructuredOutputLimited` x2, `StructuredNeedsTools`,
`RunFailure` (fields `error`, `retry`, `retry.classification`); `types.Request`
x2 (fields `tools`, `model`), `model_id`, `model_id_to_string` x2, `Usage` x5
(positional, three fields; unchanged shape), `WireError`,
`HttpStatusError(status, _, hint)`, `NoRequestSent`,
`RequestMayHaveReachedProvider`, `EffectUnknown`. Migrate to `with_output`,
`Answer(output:, text:, ..)` (`raw` is `text`), `llm_wire.tools(request)`,
`llm_wire.model(request)`, `error.Status(code, _, retry_after)` and
`failure.sent` (`NotSent`, `MaybeSent`, `Completed`).

`src/fabric/internal/registry.gleam`: `types.tool_name` x1 (validity check) →
`tool.check_name`.

Tests:

- `test/fabric/support/fake_provider.gleam`: `config.Config` x4, `config.openai`, `anthropic`, `google`, `with_endpoint` x4; `provider/{openai,anthropic,google}.options`; `testing.config`, `Reply` x2, `Events`, `Interrupted`, `Status` (an exhaustive match copying `testing.http_reply`, still needed since `http_reply` is private); `types.api_key` x3, `endpoint`, `Endpoint`.
- `test/fabric/llm_test.gleam`: `testing.Events` x7, `Status` x2, `ScriptedCall` x2, `tool_calls`, `text` x2, `refusal`, `output_limited`, `with_usage`; `types.ModelId`, `model_id`, `Usage(3, 1, 4)`. Hand-written OpenAI and Anthropic SSE helpers (L41-118, L382-447) → `testing.events_for(message.OpenAI | message.Anthropic, ..)`. Its `llm_wire.turn.v1` assertions (L225-228, L309) read the `issues` list, which is no longer stored.
- `test/fabric/graph_llm_test.gleam`: `config.Config`, `with_deadlines` (`Deadlines(0, 1, 1)` positional); `testing.config` x2, `text` x6, `with_usage` x2, `refusal`, `output_limited`, `Interrupted([])`, `Status(429, ..)`, `Events`; `types.Usage` x7, `UserMessage` x2, `model_id` x2, `new_request` x2, `tool_name`, `tool_from_codec`, `with_tools`. Inline OpenAI SSE at L394-401 → `events_for`.
- `test/fabric/llm_recovery_test.gleam`: `config.Config` x2, `config.openai`, `openai.options`; `testing.Events` x2, `Reply` x3, `Status` x2, `text` x2; `types.ModelId`, `model_id`, `api_key`. Hand-written Gemini (L81-133) and OpenAI (L361-370) SSE → `events_for` (signed Gemini parts still need hand-written events: `events_for` sends no `thoughtSignature`).
- `test/fabric/credentials_test.gleam`: `types.model_id`, `new_request`, `UserMessage`.

`consumers/decision`: `src/fabric_decision_demo.gleam` (`config.Config`, `openai`, `with_deadlines` with `Deadlines(20_000, 10_000, 1000)`; `openai.options`; `types.ModelId` x2, `Request`, `new_request`, `SystemMessage`, `UserMessage`, `with_max_tokens`, `api_key`, `model_id`) and `test/fabric_decision_demo_test.gleam` (`session.prepare_structured`; `testing.config` x2, `structured_exchange`, `text`, `with_usage`; `types.Usage`, `model_id`; reads `request.max_tokens`, now `llm_wire.request_json`).

`consumers/writing`: `src/fabric_writing/provider.gleam` (`config.Config` x2; `types.ModelId` x4, `Request` x2, `new_request` x2, `SystemMessage` x2, `UserMessage` x2, `with_max_tokens` x2), `src/fabric_writing/cli.gleam` (`config.Config`, `openai`, `with_deadlines` with `Deadlines(20_000, 10_000, 1000)`; `openai.options`; `types.api_key`, `ModelId`, `model_id`) and `test/fabric_writing_test.gleam` (`session.prepare_structured` x2; `testing.config` x8, `structured_exchange` x2, `text` x3, `refusal`, `output_limited`, `Reply`; `types.ModelId`, `model_id`).

### extractor (`oversight/apps/extractor`) — heavy

- `src/extractor/llm.gleam`: `config.Config`, `openai`, `anthropic`, `google`, `with_endpoint`, `with_deadlines` (labelled `Deadlines(overall_timeout_ms:, idle_timeout_ms:, read_timeout_ms:)`), `config.adapter` with `provider.identity` (L146, the EXT-2 workaround: delete, use `failure.provider`); `openai.options`, `anthropic.options`, `anthropic.with_version`, `google.options`; `session.prepare_structured`, `run_structured`, `PreparedStructuredCall`, `StructuredValue(value:, ..)`, `StructuredRefusal(reason:, ..)`, `StructuredOutputLimited(..)`, `StructuredNeedsTools(..)`, `RunFailure(error:, retry:)`; `types.api_key`, `endpoint`, `model_id`, `ModelId`, `WireError` x4, `Provider`, `RetryEvidence`, `Request`, `new_request`, `SystemMessage`, `UserMessage`, `with_max_tokens`, `with_temperature`.
- `src/extractor/outcome.gleam` (the 71-line failure mapping): `retry.assess`, `MayHelp` x3, `WillNotHelpUnchanged`, `Unknown` x4; `types.WireError` and every variant (`HttpStatusError(status_code:, retry_hint:, ..)`, `ProviderError(code:, message:)`, `HttpFailure` x2, `OutputValidationError` x2, `ProtocolError` x2, `DeadlineExceeded`, `ConfigurationError`, `PreparationError`, `TransportError`, `ResourceLimitExceeded(limit_name:, ..)`, `CancelledLocally`), `RetryEvidence`, `NoRequestSent`, `RequestMayHaveReachedProvider`, `EffectUnknown`, `RetryHint`, `RetryDelaySeconds`, `RetryHeaderValue`. `describe` matches `WireError` exhaustively. Replace with `llm_wire.advise(failure)` (provider no longer needed, `after` replaces the hint parsing) and `error.InvalidOutput(raw_output:, failure:)`.
- `src/extractor/jobs.gleam`: `types.WireError` → `llm_wire.Failure` or `error.Error`.
- `src/extractor/telemetry.gleam`: `telemetry.observation_event`, fields `meta.provider`, `meta.stage`, `meta.outcome` → `telemetry.event()`; `stage` and `outcome` are now enums (`stage_name`, `outcome_name`), and `meta.correlation` joins the job when the app runs the call on `http_gun.with_correlation(client, c)` (set it once, on the view).
- `test/extractor_test.gleam`: `session.prepare_structured`; `types.Anthropic`, `OpenAI`, `HttpStatusError(429, "{}", Some(RetryDelaySeconds(1)))`, `RetryEvidence(..)` x2, `RequestMayHaveReachedProvider`, `NoRequestSent` x2, `HttpFailure` → build `llm_wire.Failure(error.Status(429, "{}", Some(duration.seconds(1))), llm_wire.Completed, False, message.OpenAI, None)` and `error.Http(http_error.new(..))`.
- `src/extractor/scripted.gleam` hand-writes OpenAI, Anthropic and Google SSE (L207-358) for its loopback server; `testing.events_for` produces the same chunks.

### support_desk (`oversight/apps/support_desk`) — light

- `src/support_desk/desk.gleam`: `config.openai`, `with_endpoint`; `openai.options`; `types.api_key`, `model_id`, `endpoint`.
- `src/support_desk/telemetry.gleam`: `telemetry.observation_event`, fields `m.stage`, `m.provider`, `m.outcome`.
- `src/support_desk/provider.gleam` (no llm_wire import) hand-writes OpenAI SSE (L251-350, SD-7) → `testing.events_for(message.OpenAI, testing.tool_calls(..))`.

### tool_hub (`oversight/apps/tool_hub`) — medium

- `src/tool_hub/scripted_llm.gleam`: `config.Config`, `with_endpoint`; `testing.config`, `Reply` x3, `text`, `ScriptedCall(id:, name:, arguments_json:)` x2, `Events` x2, `Interrupted`, `Status` x2 (an exhaustive `respond` copying `http_reply`; `hold` takes the first chunk of `testing.text(..)`, unchanged); `types.endpoint`.
- `src/tool_hub/assistant.gleam`: `config.Config`, `types.ModelId` (record fields) → `llm_wire.Config`, `String`.
- `src/tool_hub.gleam`: `testing.tool_calls` x3, `text`; `types.model_id`.
- `src/tool_hub/telemetry.gleam`: `telemetry.observation_event`, `Metadata(stage:, provider:, outcome:)` destructured (L95) → `Metadata(call:, correlation:, stage:, provider:, outcome:)`.
- `test/tool_hub_test.gleam`: `testing.tool_calls` x9, `text` x5 (unchanged).

### research_agent (`oversight/apps/research_agent`) — light

- `src/research_agent/researcher.gleam`: `config.openai`, `with_endpoint`; `openai.options`; `types.api_key`, `model_id`, `endpoint`.
- `src/research_agent/telemetry.gleam`: `telemetry.observation_event`, `Metadata` (L267) with `m.stage`, `m.provider`, `m.outcome`.
- `src/research_agent/services.gleam` (no llm_wire import) hand-writes OpenAI SSE (L521-594) → `events_for`.
- `test/research_agent_test.gleam` counts events from source `"llm_wire"` (no import).

### Others

- `oversight/playground/ecosystem_pilot` uses an API removed before wave 1
  (`prepare_continue`, `Continuation`, one-argument `run`) and does not compile
  today; PLAN.md records it as superseded by tool_hub.
- relay, warden, grind, saga, sinal, json_blueprint, http_gun, secure_mcp,
  sso_portal, webhooks and checkout do not import LLM Wire.
