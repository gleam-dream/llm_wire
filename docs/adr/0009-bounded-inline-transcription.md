# Keep inline transcription in the main wire library

<a id="adr-0009"></a>

## Decision

The owner accepted main-library transcription on 2026-10-09 after an independent
consumer qualified eight offline scenarios and four controlled provider calls.
Add a distinct `llm_wire/transcribe` family for inline Google Interactions audio.
The public result is a native nonempty String. Preparation admits bytes and
settings without I/O; execution borrows the caller's HTTP Gun view unchanged.

A plain settings record exposes model, language hints and typed Verbatim/Smart
mode. Opaque audio/prepared values enforce admission and keep credentials out of
ordinary inspection. The encoded request remains explicitly inspectable without
headers. MIME admission follows the provider's documented list, not one
application's upload policy. Model and locale support remain provider decisions.

The request disables provider storage and performs one attempt. The caller owns
retention, durable identity, authorization and whether another attempt is safe.
Transport failures retain HTTP evidence. Incomplete or malformed text never
becomes an apparently successful partial transcript. The native family reuses
common failures and observations; no agent runtime, FFI or application dependency
is introduced.

## Alternatives and limits

A companion package was viable, but the owner selected the main library. Adding
audio to generation content alone would not express this separate non-streamed
protocol. A general Interactions client, remote uploads and a Fabric execution
loop would exceed the qualified need. The existing Google generation options
remain specific to generation; `transcribe.google` constructs only this family's
configuration, without a public secret accessor or a second constructor path.

HTTP Gun's body-limit setter replaces the view's allowance. The transcription
runtime therefore does not use it to silently overwrite caller policy; the
caller supplies a bounded client and the runtime refuses truncation. Input,
encoded request and response limits act at different allocation boundaries.
No universal pre-allocation or remote-cancellation guarantee is asserted.

The narrower inline contract resolves only this part of ADR 0006's advanced
lifecycle ruling. Other lifecycle, allocation and conformance entries remain.
Normal gates are offline. The earlier synthetic live samples demonstrate that
request shape, not arbitrary audio quality, future model support or this final
implementation's release readiness.

Sources checked 2026-10-09:
[Google transcription](https://ai.google.dev/gemini-api/docs/transcribe) and
[Interactions retention](https://ai.google.dev/gemini-api/docs/interactions-overview).
