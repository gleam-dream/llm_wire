# LLM Wire Wave 4 progress

## Starting point

Wave 4 started from LLM Wire baseline `188c70b`, preserving the existing dirty
and staged work. The package remains partial by design; this file records the
gap-closing work and its proof rather than declaring the wave complete.

## Milestone 1: Google continuation state

The first vertical slice preserves Gemini's opaque `thoughtSignature` across
the complete signed model-part sequence used for a tool continuation. The
internal tool-call record keeps provider state separately from the provider
call ID, while the continuation carries the raw model parts in their original
order. Google reduction accepts valid signatures on text and other non-tool
parts, and malformed signature values fail as typed protocol errors. The public
facade still exposes its smaller stable `ToolCall` shape.

The loopback test now sends signed Gemini text and function-call parts,
prepares a typed tool-result continuation, and requires the second local
request to contain the complete signed model turn in order. Reducer-level
regressions also prove non-tool state is retained and malformed signatures
produce a typed protocol error.

## Milestone 3: typed content and cache references

The public request model now admits text, remote image URL, and inline base64
image parts. OpenAI encodes user text as `input_text`, assistant text as
`output_text`, and admitted image parts as `input_image`; Anthropic and Google encode text
and inline image parts and reject remote URLs outside their current adapter
profiles before transport.
Provider cache references are explicit variants: OpenAI's
`prompt_cache_key` and Google's `cachedContent` are encoded and cross-provider
use is rejected during preparation. Anthropic content-block cache breakpoints
remain a separate complexity candidate.

Three selected ReqLLM v1.24.0 behaviors are ported into
`test/llm_wire_wave4_oracle_test.gleam`, with the source path, revision, and
Apache-2.0 attribution recorded in `test/oracle/README.md`.

The three ports cover the assistant multi-content message boundary, structured
Responses tool output encoding, and ordered user/assistant input message
encoding. Google tool-turn ordering, inline image, Gemini cache-reference, and
provider-state cases remain explicit local regressions because their selected
upstream triggers differ.

## Milestone 2: pool waiter state repair

The signed Google test exposed a timing-sensitive existing pool defect: the
waiter path inserted `{noreply, State}` into the GenServer state when a waiter
was served from a connection-result or cleanup callback. The pool now has a
state-returning connector helper for those callbacks while the `handle_call`
path retains its GenServer reply tuple. This removes the crash and the related
spurious `noproc` stop result. A deterministic test now queues a waiter, kills
the leased stream owner, and requires the waiter to receive the next
connection's response after the cleanup callback.

## Synchronous proof so far

- `nix develop --command gleam format src test` — pass.
- `nix develop --command gleam check --target erlang` — pass.
- `nix develop --command gleam test --target erlang` — 133 passed, no failures.
- `nix develop --command gleam build --target erlang` — pass.
- `nix develop --command sh test/external_package_boundary.sh` — pass.
- `nix flake check` — pass for the available `aarch64-darwin` check.
- `git diff --check` and `git diff --cached --check` — pass.

The expected TLS alert notices from negative local TLS fixtures still appear;
the test process exits successfully. No provider, credential, commit, push, or
remote operation was used.

## Open Wave 4 scope

Broader multimodal parity, embeddings, Anthropic content-block caching,
provider option, usage, reasoning and stop coverage, durable/versioned
continuation, bounded retry where replay safety is proven, lifecycle
observations, and batch, background, remote-cancellation, or realtime
feasibility remain open. The header pre-allocation requirement still needs an
evidence-backed dependency decision. Detailed usage parity and durable
serialization remain open even though the current thought signature is
retained in process-local continuation.
