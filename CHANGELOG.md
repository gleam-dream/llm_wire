# Changelog

## Unreleased

- Inline Google audio transcription adds typed admission and settings, pure preparation, completed text and common failure evidence. It uses the caller's HTTP view unchanged and introduces no retries, persistence or agent runtime.

- Initial 0.1.0 candidate for Gleam on Erlang/OTP; no published release history is claimed.
- One generic generation family supports text and application-native structured output through OpenAI Responses, Anthropic Messages, Google GenerateContent and public custom adapters.
- Pure preparation validates settings, schemas, conversations and byte limits before execution. Typed outcomes distinguish answers, complete tool requests, partial output and model refusal; content filtering remains a typed failure.
- Owned streaming provides whole-call, first-progress and event-idle bounds, finite SSE/progress/argument/metadata buffers, shared close and creator-death cleanup. The application supplies its HTTP Gun client.
- The caller owns history, tool execution, authorization, retry and persistence. Message/turn/replay codecs preserve provider-required data and existing Fabric turn records.
- Classification adds native questions, heterogeneous batches, complete distributions and optional confidence/usage. Pure typed wires remain independent of live auth/settings; bounded receipt codecs reconstruct current and legacy TypeSafe evidence without credentials.
- Semantic test builders lower through provider reducers into HTTP Gun scripts/cassettes. The separate public consumers and local H1/TLS/H2 harness provide scoped offline/local checks; opt-in provider recording remains separate.
- [Decision records](docs/adr/) preserve ownership, facade, schema/filter, oracle, classification and retained-capability rationale from the unpublished construction history. [Native design](docs/design/design.typ) records current behavior and unresolved contracts; [testing guidance](docs/testing.md) records commands and evidence limits.
