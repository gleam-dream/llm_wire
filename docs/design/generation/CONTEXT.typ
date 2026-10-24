#let accent = "blue"

#let terms = (
  (slug: "term-prepared-generation", title: [Prepared generation], body: [One admitted and encoded generation request with its provider, settings and output decoder. It is a reusable value rather than an executing operation.]),
  (slug: "term-generation-settings", title: [Generation settings], body: [An immutable value holding optional maximum output tokens, temperature, top-p, stop sequences and one provider cache reference. It holds no model, messages, tools, credentials or output codec.]),
  (slug: "term-stream-owner", title: [Stream owner], body: [The authoritative process holding one generation execution's framing, reduction, delivery and terminal state. Copied stream handles name the same owner.]),
  (slug: "term-semantic-progress", title: [Semantic progress], body: [Accepted text, refusal, reasoning or tool-argument output from a generation response. Usage reports and extension notifications are not semantic progress.]),
  (slug: "term-assistant-turn", title: [Assistant turn], body: [One response's text, application tool calls, provider identity and message-local replay data. It contains no conversation history or execution capability.]),
  (slug: "term-replay-data", title: [Replay data], body: [Provider-owned response data required to encode that assistant turn in a later caller-supplied conversation. It is not a durable execution checkpoint.]),
  (slug: "term-tool-call-issue", title: [Tool call issue], body: [An undeclared tool name or invalid argument value reported beside a complete tool-request turn under the reporting policy. It does not establish permission to execute that call.]),
  (slug: "term-provider-adapter", title: [Provider adapter], body: [The encoder, schema projection, header callbacks and event reducer that give one provider protocol its meaning. Shared admission, limits, timers and cleanup stay outside it.]),
  (slug: "term-application-deadline", title: [Application deadline], body: [An explicit absolute deadline carried by the HTTP client the caller supplies. A generation can shorten its own budget below it and cannot extend it.]),
  (slug: "term-send-evidence", title: [Send evidence], body: [The conservative classification NotSent, MaybeSent or Completed attached to a failed interaction. It describes observed reachability and completion rather than effect rollback or replay safety.]),
  (slug: "term-provider-delay", title: [Provider delay], body: [The provider's readable Retry-After duration, distinguished from caller-selected backoff. It has no package-imposed maximum.]),
  (slug: "term-retry-advice", title: [Retry advice], body: [A prospect for another attempt and the owner of the wait, derived from one failure alone. It schedules nothing and does not say that a repeat is safe.]),
  (slug: "term-observation", title: [Observation], body: [A bounded lifecycle fact reported through Sinal with call identity, correlation, stage, provider and outcome. It carries no content or credentials and authorizes nothing.]),
  (slug: "term-semantic-test-reply", title: [Semantic test reply], body: [An opaque description of a provider response, such as text, tool calls, refusal or failure, lowered through the real provider reducer into scripted HTTP exchanges.]),
  (slug: "term-live-recording", title: [Live recording], body: [An opt-in run that sends real requests to a commercial provider and publishes a sanitized cassette. It spends provider tokens and is never part of an ordinary gate.]),
  (slug: "term-oracle-evidence", title: [Oracle evidence], body: [Selected behavior of a pinned upstream implementation compared against local assertions. It establishes named laws and no parity with the upstream suite.]),
  (slug: "term-public-consumer", title: [Public consumer], body: [A separate package that depends on this library through public imports only, exercises its adoption path, including compile-time refusals, and holds the compiled, offline programs that serve as the usage documentation.]),
)
