# Carry the provider's error code and message on an error status

<a id="adr-0023"></a>

## Decision and alternatives

- An error status was `error.Status(code: Int, body: String, retry_after)`. Rate limits, exhausted quotas, overloads, prompts that are too long and authentication failures were the same shape, told apart only by parsing `body`, which the error module tells callers never to do. `advise` mapped by HTTP status alone, so OpenAI's `insufficient_quota`, a 429 that waiting does not fix, was advised `MayHelp`, although the in-stream code table already knew better.
- On 2026-11-25 the repository owner ruled that the provider's error detail becomes typed fields of `Status` itself, as a breaking change, with no parallel accessor. `Status` is now `Status(status: Int, code: Option(String), message: Option(String), body: String, retry_after: Option(Duration))`. The HTTP status field is renamed from `code` to `status`, so that `code` means the provider's code in `Status` as it does in `Provider(code, message)`.
- One reader decodes the envelope the three built-in providers share under `error`: OpenAI `error.code`, or `error.type` when the code is null; Anthropic `error.type`; Google `error.status`, its canonical code (its `error.code` repeats the HTTP status). `message` is `error.message`. An OpenAI-compatible server or a custom provider that uses one of these envelopes is read the same way. A body without the envelope, such as a proxy's page, yields neither field, and `body` keeps the text as sent.
- `advise` reuses the per-provider code table for `Status`: a code it knows decides before the status, and an unknown or absent code leaves the status in charge.
- `error.describe` names the status and the code but leaves the message out: an authentication message can quote part of the key, and the description is meant for logs.
- Rejected: a typed classification such as `ContextTooLong` or `QuotaExhausted`. Each provider spells these conditions differently (OpenAI `context_length_exceeded`; Anthropic an `invalid_request_error` whose only signal is its message), so a classification would either parse prose or claim a precision it does not have. The provider's own code is exact and lets the application decide.
- Rejected: an accessor function that parses `body` on demand. It would leave two ways to read the same fact and keep the untyped shape as the primary one.
- Rejected: a per-adapter decoding callback. The three envelopes differ only in which member names the code, so one reader covers them, and a custom adapter gains nothing it must implement.

## Evidence and limits

- `test/llm_wire_status_error_test.gleam` serves error bodies shaped as each provider documents them. Before the change, OpenAI's `insufficient_quota` 429 failed as `Status(429, "{\"error\":{...\"code\":\"insufficient_quota\"}}", None)` and `advise` answered `MayHelp`.
- Classification and transcription keep no error body, as before, so their `Status` carries neither field.
- The body shapes follow the providers' error documentation as read on 2026-11-25 and the shapes this repository's testing kit already sends; no live error was recorded.
