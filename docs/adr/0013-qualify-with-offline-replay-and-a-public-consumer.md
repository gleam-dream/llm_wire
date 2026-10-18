# Qualify behavior with offline replay and a public consumer, and make live recording opt-in

<a id="adr-0013"></a>

## Decision and alternatives

- Ordinary gates run against local and offline inputs: scripted and recorded HTTP exchanges, semantic test replies lowered through the real provider reducer, a separate public-import consumer package and a local H1, TLS and H2 harness. Live provider recording is a separate opt-in operation that spends tokens and never belongs to a gate.
- Replay never falls back to a network. A missing, corrupt, incompatible, mismatched or exhausted exchange fails, and a mismatch leaves the expected exchange unconsumed, so a test cannot pass by reaching a real provider.
- The public consumer is a separate package with compile-time refusal fixtures. Negative fixtures compile against a positive compiled control with `compile-package --no-beam`, so a missing dependency cannot impersonate an intended type error.
- Substituting a final answer at the high level was rejected as provider-reduction evidence, because it skips the reducer that the behavior depends on. Recording on every gate run was rejected because it spends tokens and makes results depend on provider availability.

## Evidence and limits

- CI runs the full gate on every push, pull request, manual run and weekly schedule. A final job rejects failed, cancelled and skipped mandatory jobs. The checkout persists no credentials, and fork pull requests run the same checks. Weekly runs record finite HTTP observations without a latency ceiling.
- Sanitized named OpenAI, Gemini and TypeSafe cassettes support those named requests at their recorded revision and model, not every offered model. HTTP Gun removes its documented credential metadata; prompt bodies, queries and unlisted headers can retain sensitive content and remain the recorder owner's responsibility.
- Formatting runs against a copied Nix tree so a gate never repairs the working tree. Frozen request fixtures, cassettes, oracle provenance, retained evidence and generated output are excluded from automatic formatting.
- A passing log is evidence for its recorded revision and runtime only. This record consolidates the testing guidance that preceded the design layer's verification section.
