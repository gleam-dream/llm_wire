# Changelog

Release notes begin with the first published version ([ADR 0016](docs/adr/0016-record-unpublished-changes-in-adrs-not-a-changelog.md)). Present behavior lives in the design layer, and the reasons for each change live in the ADRs.

## 0.2.1

This release lets an application use OpenAI's Responses API with documents, codecs with optional fields, and responses OpenAI does not keep ([ADR 0021](docs/adr/0021-send-files-optional-answer-fields-and-unstored-responses.md)). No signature changes.

### Added

- **`message.InlineFilePart(mime_type:, file_name:, base64_data:)`, a stored file such as a PDF or a photo.** A document is sent as the provider's file:
  - **OpenAI:** `input_file` with `filename` and a base64 data URL in `file_data`.
  - **Google:** `inlineData`, as for an inline image. Gemini has no field for the file name.
  - **Anthropic:** a base64 `document` block titled with the file name. Only `application/pdf` is admitted as a document.
  - `message.to_json` and `message.decoder` store it as `{"type": "inline_file", ...}` in the existing `llm_wire.message.v1` format.
  - A file part with an image media type is sent as the provider's image, exactly as an `InlineImagePart`, so photos and PDFs can travel as one kind of part. No provider has a field for an image's name.
- **`error.FileTypeUnsupported(media_type:)`:** Anthropic refuses a file part that is neither a PDF nor an image during preparation. `error.describe_prepare_error` describes it.
- **`openai.with_store(options, store)` sends `"store": store` on every Responses request.** Without it the field is left out and OpenAI's default (stored for 30 days) applies, as before.

### Changed

- **OpenAI and Anthropic structured output admits optional fields.** A codec with `codec.optional_field`, at any depth (nested records, list items, union payloads), used to fail preparation with `error.UnsupportedSchema`. Such a field is now sent as required and nullable, which OpenAI's and Anthropic's strict mode demand. Google's schema is unchanged.
- **A `null` for an optional field is removed from the answer before it is decoded, on every provider.** Only a field whose own codec is not `nullable` (or `codec.value()`) loses its `null`; a nullable field keeps it.
  - `Answer.text` is the cleaned JSON when a member was removed: compact, with members in the codec's field order and exact numbers. Otherwise it is the provider's text unchanged.
  - `error.InvalidOutput.raw_output` is cleaned the same way when the text is JSON, so a correction turn can decode it with the same codec. Text that is not JSON stays as the provider sent it.
- **OpenAI function tools are sent with `"strict": false`.** Before, the field was absent and OpenAI normalized a tool schema into strict mode when it could. Now the caller's schema is used as given: optional arguments stay optional, and arguments reach the caller exactly as the model wrote them.

### Fixed

- **OpenAI tool calls no longer fail as "Duplicate tool block completion".** OpenAI streams `response.function_call_arguments.done` before `response.output_item.done` for every function call, and 0.2.0 treated both as the call's completion, so every real OpenAI tool call failed with a protocol error. The arguments event now only confirms the arguments, and the scripted OpenAI replies of `llm_wire/testing` send it as OpenAI does.

### Compatibility

- `message.Content` and `error.RequestProblem` each gain variants. Both are documented to gain variants and to be matched with a `_` arm; a `case` over either without one stops compiling. Fabric 0.4.0 and dash-crm have none.
- Fabric's requirement `>= 0.2.0 and < 0.3.0` admits this release.

### Who must change

- **dash-crm:**
  - Send stored originals, PDFs and photos alike, as `message.InlineFilePart` instead of `message.InlineImagePart` with `application/pdf`, which OpenAI refuses as an image.
  - Raise `limit.RequestBytes` with `llm_wire.with_limit` to fit the files it sends; the default is 1 MiB.
  - Add `openai.with_store(False)` to its OpenAI options.
  - Its agent codecs with optional fields now prepare on OpenAI, and `Answer.text` and `InvalidOutput.raw_output` decode with the same codec.
  - Its tools are sent non-strict on OpenAI, so optional arguments stay optional.

### Limits

- OpenAI's encrypted reasoning is not carried, by decision. Under `store: false`, a tool round replays its calls as new input without the earlier reasoning items, and the model loses that reasoning.

## 0.2.0

### Breaking

- **`message.Usage` gains `thought_tokens: Option(Int)`.** Every construction of `message.Usage(...)` that does not name the new field stops compiling, positional or labelled. Code that only reads fields by label, or matches with `..`, is unaffected. Add `thought_tokens: None` (or `, None` positionally) where you build a usage value, for example in a custom adapter's reducer or in a test that passes one to `testing.with_usage`.
- **`output_tokens` counts every generated token, thoughts included, on every built-in provider.**
  - OpenAI and Anthropic already counted reasoning there.
  - Google's figure now adds `thoughtsTokenCount` to `candidatesTokenCount`, so Gemini output counts grow.
  - `thought_tokens` holds the provider's thought count where it reports one.
  - Totals, budgets and dashboards built on Gemini `output_tokens` change in value, not in meaning: the value is now what the output limit bounds ([ADR 0020](docs/adr/0020-state-a-thinking-level-and-count-thought-tokens.md)).
- **`error.RequestProblem` gains `ThinkingUnsupported(problem: ThinkingProblem)`.** An exhaustive `case` over `RequestProblem` needs an arm for it. `error.describe_prepare_error` describes it.
- **`provider.Request` gains `thinking_level: Option(thinking.Level)`.** Custom adapters that read the request by label are unaffected. One that cannot carry a level should refuse it from `encode` rather than drop it.

### Added

- **`generation.with_thinking_level` and `llm_wire.with_thinking_level` set a `thinking.Level`.** The levels are Minimal, Low, Medium, High, ExtraHigh and Max. Each built-in provider writes the level in its own form:
  - **OpenAI:** `reasoning.effort`.
  - **Google:** `thinkingConfig.thinkingLevel`.
  - **Anthropic:** adaptive thinking with `output_config.effort`.
- **Preparation refuses a level the provider has no value for:** Google `Max` and Anthropic `Minimal`. It also refuses a level on Anthropic while the conversation's last assistant message contains a tool call.
- **Anthropic thinking blocks are read as reasoning progress.** Before this, an Anthropic response with a thinking block failed as a protocol error.

### Who must change

- **Fabric:**
  - Widen its `llm_wire` requirement (`>= 0.1.0 and < 0.2.0`, in the root and in the `app`, `decision` and `writing` consumers) to admit 0.2.0.
  - Add the new field where its tests build `message.Usage(...)`: `test/fabric/llm_test.gleam` and `test/fabric/graph_llm_test.gleam`.
  - Its source reads usage by label and compiles unchanged. Gemini output counts reaching `run.TokenUsage` now include thoughts.
- **dash-crm:**
  - Widen its `llm_wire` requirement (`>= 0.1.1 and < 0.2.0`) to admit 0.2.0.
  - Its source reads usage by label and formats prepare errors with `error.describe_prepare_error`, so it compiles unchanged.
  - Its Gemini output counts now include thoughts.
  - To bound thinking, set `llm_wire.with_thinking_level(thinking.Low)` and leave headroom in `with_max_tokens`. The limit counts thought and visible tokens together, and no level reserves a visible share.
