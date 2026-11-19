# Send files, optional answer fields and unstored responses to OpenAI

<a id="adr-0021"></a>

## Decision and alternatives

- **The problem.** dash-crm moves every agent from Gemini to OpenAI's Responses API, and the owner ruled on 2026-11-19 that LLM Wire closes three gaps itself instead of the application working around them or forking.
  - A PDF had no part of its own. dash-crm sent it as `InlineImagePart` with `application/pdf`, which Gemini reads as inline data and OpenAI refuses as an `input_image`.
  - OpenAI's and Anthropic's strict structured output refused any record with an optional field, while dash-crm's agent codecs use `codec.optional_field`.
  - OpenAI keeps every response for 30 days unless the request sends `store: false`, and the adapter had no way to send it.
- **A file part.** `message.Content` gains `InlineFilePart(mime_type:, file_name:, base64_data:)`, a document the provider reads as a file.
  - **OpenAI:** `{"type": "input_file", "filename": file_name, "file_data": "data:<mime_type>;base64,<data>"}`. Any media type other than an image is passed through; OpenAI decides which it reads.
  - **Google:** `inlineData` with `mimeType` and `data`, as for an inline image. Gemini's `inlineData` has no name field, so the file name is not sent.
  - **Anthropic:** a `document` block with a `base64` source and the file name as its `title`. Anthropic's base64 document source takes only `application/pdf`, so preparation refuses any other media type with `InvalidRequest(FileTypeUnsupported(media_type))`.
  - The message codec stores it as `{"type": "inline_file", "mime_type", "file_name", "data"}` in the same `llm_wire.message.v1` format.
- **An image in a file part is refused on every provider**, with `InvalidRequest(ImageInFilePart(media_type))`, before anything is sent. A media type is an image when its type, compared without case and parameters, is `image`.
  - Rejected: sending it as an image. The conversion would drop the file name the caller asked for, which the design's rule against silently discarding requested features forbids, and it would make one part kind mean two wire forms. OpenAI's `input_file` is documented for documents, so sending the image as a file would fail at the provider instead.
  - The caller knows the media type already, so choosing `InlineImagePart` for an image is one branch at the call site.
  - `InlineImagePart` keeps its behavior: its media type is not checked, so the PDF-as-image form Gemini accepts still reaches Gemini unchanged.
- **Optional fields in strict output.** OpenAI and Anthropic projections send an optional property as required and nullable: its name joins `required` and its schema becomes `{"anyOf": [{"type": "null"}, schema]}`, Blueprint's own nullable form. A property already nullable keeps its schema and only joins `required`. The rule applies at every depth: nested records, list items and union payloads. Google's projection is unchanged, because `responseJsonSchema` honours `required`.
- **The answer is cleaned before it is decoded.** For every provider, custom adapters included, the parsed answer is walked against the output codec's schema, and a `null` member is removed where the property is optional and its schema admits no `null` (it is neither nullable nor `codec.value()`). The cleaned value is then validated against the original contract and decoded by the original codec.
  - `Answer.text` is the cleaned JSON when a member was removed, written compactly with exact numbers, and the provider's text unchanged otherwise. dash-crm's agent library decodes `Answer.text` itself with the original codec, so the text must be what that codec accepts.
  - `InvalidOutput.raw_output` stays the provider's text, the evidence of what the model sent.
  - The cleaning is not tied to the strict projection. A `null` where the caller's schema allows only absence can mean nothing but absence, and the original codec would refuse it, so removing it is safe for any provider.
  - A property declared nullable keeps its `null`: `optional_field` with `nullable` decodes it as `Some(None)`.
  - Rejected: decoding `null` as absent inside the codec. Blueprint's `optional_field` rejects `null` by design, and the codec belongs to the caller.
  - Rejected: requiring callers to declare `nullable` fields for strict providers. Their codecs also describe stored data and other providers.
- **Unstored OpenAI responses.** `openai.with_store(options, store)` sends `"store": store` on every Responses request. Without it the field is left out, so OpenAI's default (stored) applies, as before.
  - The default stays unchanged because flipping it would change every existing caller's stored data and response retrieval without a compile error, in a release that Fabric's `< 0.3.0` requirement admits.
  - LLM Wire replays the whole conversation and never reads a stored response, so the library itself needs no stored response. Whether `false` should become the default is left as a pending ruling for the next breaking release.
- **Reasoning items across tool turns are left pending.** Under `store: false`, OpenAI can return reasoning items with `encrypted_content` when the request sends `include: ["reasoning.encrypted_content"]`, and expects them back before the tool calls they preceded. Carrying them needs the OpenAI reducer to keep reasoning items, the assistant turn's replay data to hold them and the encoder to replay them, the same gap as Anthropic thinking in tool rounds. Without them a tool round still works; the model does not see its earlier reasoning. It is recorded as a pending entry beside the Anthropic one.
- **The version.** These changes ship as 0.2.1.
  - `message.Content` and `error.RequestProblem` each gain variants. Both are documented to gain variants in a minor release and to be matched with a `_` arm, so a `case` written that way compiles unchanged.
  - A `case` over either without a `_` arm stops compiling; neither Fabric 0.4.0 nor dash-crm has one.
  - No signature changes. A codec with an optional field that preparation refused before now prepares.

## Evidence and limits

- The wire forms follow the providers' documentation: OpenAI's file inputs for the Responses API (each file and all files of a request under 50 MB), its structured outputs guide (every property required, `additionalProperties: false`, optional emulated as a union with `null`) and its statement that responses are stored for 30 days unless `store` is `false`; Anthropic's PDF support (`document` with a `base64` source); Gemini's `inlineData`. No live recording was made for this change.
- Request bodies are bounded by `limit.RequestBytes`, 1 MiB by default. A caller sending files raises it with `llm_wire.with_limit`; OpenAI's 50 MB request cap is the provider's to enforce.
- `test/llm_wire_file_part_test.gleam` pins each provider's file encoding, the refusals and the codec round trip. `test/llm_wire_optional_output_test.gleam` pins the projection for nested records, list items, union payloads and nullable properties, and the cleaning across all three providers. `test/llm_wire_openai_store_test.gleam` pins `store`.
