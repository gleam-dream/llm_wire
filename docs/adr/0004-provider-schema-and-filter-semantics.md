# Admit provider schemas explicitly and separate content filtering

<a id="adr-0004"></a>

## Decision and alternatives

- Provider profiles admit the complete Blueprint schema at its tool/output location. Refusal is local and explicit; silently weakening unsupported shapes or treating all Blueprint schemas as portable would change the caller's contract.
- Strict output keeps a record root and rewrites nested tagged unions to anyOf variants with one-element enum tags. Native response validation still uses the original codec; projection does not replace runtime validation.
- Google uses responseJsonSchema for structured generation, including nullable/optional/range/pair/any nested fields; OpenAI and Anthropic retain the narrower required-object profile. Sending the same JSON under Google's responseSchema produced a live unknown-additionalProperties rejection; treating field names as equivalent was rejected by provider evidence.
- Provider content-filter stops are ContentFiltered failures with native reason/stage, distinct from model-authored Refused text. A safety stop should not appear as ordinary token exhaustion or an interchangeable model refusal, and advise requires the request to change.

## Evidence and limits

- Union admission is [0e4f01a](https://github.com/gleam-dream/llm_wire/commit/0e4f01ad30673601031c4f44fe78ff4f12949e07); content filtering is [1d86251](https://github.com/gleam-dream/llm_wire/commit/1d862517f56bfb0467910db14622fea55e0594a9); Google field correction is [59dbe66](https://github.com/gleam-dream/llm_wire/commit/59dbe665380f4be82b847094581230ea83350353); the wider Google profile is [ae4bb8b](https://github.com/gleam-dream/llm_wire/commit/ae4bb8b0ecdc56a70706bcc4bd4f0bc10b2a863a).
- Recorded 2026-10-04 requests against gemini-3.8-flash and gpt-4.1-mini support named union/profile cases only. Their sanitized cassettes, request fixtures, replay tests and union/schema-consistency tests remain; this migration makes no live call or new provider claim.
- Actual [projection code](https://github.com/gleam-dream/llm_wire/blob/4726271d1671f48fe63222bc2133af1aacfe60e9/src/llm_wire/internal/schema.gleam) resolves earlier broad/stale coverage statements. Tool-parameter admission remains narrower than Google's output profile.
