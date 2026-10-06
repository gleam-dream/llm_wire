# Separate pure classification protocols from live settings

<a id="adr-0008"></a>

## Decision and alternatives

- Classification lives in core LLM Wire as a separate non-generative request family. A typed wire projects QuestionView and returns untrusted Answer candidates; shared admission retains native values, exact ids, full distributions, rubric agreement and numeric evidence.
- The earlier TypeSafe-shaped extension JSON would require a second wire to manufacture the first provider's envelope. Typed candidate vocabulary removes that coupling; TypeSafe still checks its own mandatory fields and precision before Float conversion.
- Wire holds pure projection/default endpoint and fixed receipt bounds. Config holds fresh credentials, optional endpoint, timeout and live byte policy. A durable operation fixes its wire/version and codec while obtaining fresh Config after approval or restart; capturing live settings in receipt decoding would make historical evidence depend on current secrets/policy.
- Confidence and usage are optional only when the wire permits absence. Fabricated zero/confidence and weakened TypeSafe mandatory checks are rejected alternatives; concentration is not correctness probability.
- Live byte bounds must be positive and at most fixed receipt bounds, checked before credential access. The parser uses those admitted bytes without restoring a hidden 1 MiB cap; structural/numeric limits remain. The enclosing storage record has its own bound because escaping and saved state differ from protocol byte lengths.

## Evidence and compatibility

- [accb950](https://github.com/gleam-dream/llm_wire/commit/accb950ba7ba2e70be643ef2be68baf896d08d2f) introduces core classification; [e31f26f](https://github.com/gleam-dream/llm_wire/commit/e31f26f48ceea9271aca6e3765191c19b1a0f76f) repairs effective byte limits; [c869b1c](https://github.com/gleam-dream/llm_wire/commit/c869b1c93cbf3ac302cecfbc9f1e282be0325854) separates pure/live lifetimes and typed extension vocabulary.
- The [typed composition decision](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/docs/release-api/DECISIONS.md) and plan follow-up record the approved direction. The retained independent array-envelope consumer and question/protocol/receipt tests exercise native labels, heterogeneous batches, absent measurements, custom headers, malformed evidence and pure reconstruction.
- The current llm.classification.receipt.v1 codec also reads fabric.typesafe.receipt.v1. It re-encodes the expected request and canonically compares saved evidence, then validates candidates; encoding additionally rejects a native outcome inconsistent with that evidence. Fresh credentials are absent from codec capture.
- One recorded TypeSafe request on 2026-10-05 resolved jev-latest to jev-1.13.0. Its redacted offline cassette remains; it does not certify future models or another wire. The migration makes no live provider request.
