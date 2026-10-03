# HTTP Gun ownership contract

Accepted 2026-09-30 under the migration specification. This supplements
[caller-owned conversations](caller-owned-conversation.md) and supersedes the
older transport/pool/cassette implementation descriptions. The parent oversight
document and sibling applications remain untouched.

## Public boundary

An application starts or supervises one shared `http_gun.Client`. It prepares
provider requests with pure `session.prepare` / `prepare_structured`, then passes
the client to `run`, `stream`, `run_structured` or `stream_structured`. Prepared
calls remain opaque, with no public raw-HTTP execution or credential accessor.
Only the internal adapter converts an admitted call to `Request(BitArray)`.
The standalone [consumer](../examples/consumer/README.md) compiles these paths
against the actual checkout; the external gate rejects raw requests, constructor
access, stored-field access and removed continuation/checkpoint/pool APIs for
their intended compiler reasons.

HTTP Gun owns connection and stream admission, verified TLS, HTTP flow control,
body ownership, byte streaming, HTTP cancellation/deadlines and HTTP fixtures.
LLM Wire owns endpoint admission, encoding/reduction, bounded SSE, progress,
semantic idle, tool/result admission, structured output and semantic evidence.
The caller owns history, tool execution, retry decisions and persistence.

## Session lifetime

Each execution creates one absolute deadline before reducer/owner startup.
Preparation does not start time. The same deadline enters an HTTP Gun
`with_deadline` view and the semantic owner; admission, connection, headers and
body consume it. A spent deadline remains zero. No public caller-supplied
absolute deadline is introduced. The view's deadline replaces the client's
request timeout, and the view lifts the client's idle timeout, so neither HTTP
Gun default cuts LLM Wire's overall, idle or first-token waits.

The semantic owner creates one linked Gleam worker. That worker creates its
cancellation token and keeps the `with_token` scope open throughout HTTP opening,
reading and closing. The same worker opens and consumes the HTTP body. It sends
one chunk, then waits for one credit from the semantic owner. The owner admits
progress into finite count/byte queues and grants further credit only below its
watermarks. There is no eager byte-forwarding loop, second body server or Erlang
orchestration server. HTTP Gun's configured body queue is a separate finite
upstream bound; these application bounds do not certify Gun parser allocation.

`stream` returns after owner setup, before HTTP headers. Opening failures arrive
through a terminal result, so a caller can close during admission, connection or
headers. Close latches the token and releases the worker; HTTP scopes close on
return or exception. The worker is linked to the owner; abnormal owner exit ends
it and HTTP Gun observes opener death. The owner also monitors its creating
consumer and pending readers. Creating-consumer death cancels the session;
copied handles share state and do not transfer lifetime.

| Event                             | Observable result                                                                       |
| --------------------------------- | --------------------------------------------------------------------------------------- |
| HTTP read-wait expires            | Retain HTTP and the outstanding credit; worker retries its wait                         |
| Consumer read-wait expires        | Settle/cancel only that pending semantic read; later reads remain legal                 |
| Semantic idle expires             | Terminal `DeadlineExceeded(IdleDeadline)`; keepalive/non-progress bytes do not reset it |
| Fixed overall budget expires      | Terminal `DeadlineExceeded(OverallDeadline)` and local cleanup                          |
| Concurrent copied-handle read     | Explicit `ConcurrentReadConflict`                                                       |
| Provider terminal before HTTP EOF | Deliver semantic terminal and close locally immediately; no drain                       |
| Local close                       | `ConsumerClosed` or `AlreadyTerminal`; concurrent close and exit races are idempotent   |
| Shared client shutdown            | Outstanding sessions receive typed failure and release their workers                    |

Terminal delivery settles against pending-read cancellation and owner exit;
already delivered terminal responses win the race. A late HTTP error cannot
replace a terminal. Local cancellation never establishes provider cancellation,
rollback or safe replay. Closing one H2 stream preserves siblings.

## Typed failure and retry evidence

HTTP diagnostic strings are never parsed for categories. The adapter preserves
the typed reason in `types.HttpFailure`, except the two semantic translations:

| HTTP outcome / observation            | LLM outcome / evidence                                                       |
| ------------------------------------- | ---------------------------------------------------------------------------- |
| `DeadlineExceeded`                    | `DeadlineExceeded(OverallDeadline)`                                          |
| `Cancelled`                           | `CancelledLocally`                                                           |
| Any other typed `Reason`              | `HttpFailure(reason)`; retry prospect stays unknown                          |
| `NotSent`                             | Initial classification `NoRequestSent`                                       |
| `MaybeSent`                           | Initial classification `RequestMayHaveReachedProvider`                       |
| Independently observed response bytes | OR into `response_bytes_observed`; never erase them on a later failure       |
| Reducer or admitted semantic progress | OR into `semantic_progress_observed`; retain stronger reducer classification |
| Existing `EffectUnknown`              | Remains dominant                                                             |

HTTP evidence is one input, merged monotonically with reducer evidence; LLM Wire
never reinterprets it. A stopped client and a request-size rejection provide
the tested `NotSent` cases. A local reset never produces
`ProviderCancellationConfirmed`.

LLM Wire interprets status and response headers. Only status 200 with
`text/event-stream` and absent/identity encoding enters SSE. Non-200 bodies are
collected under the smaller of 64 KiB and the semantic body limit. Status errors
retain a bounded body and typed numeric/raw Retry-After hint for the caller;
no complete body or credentials enter telemetry. Oversized error bodies fail
with a resource limit. HTTP Gun supplies response data without retry, redirect
or decompression. Provider terminal/refusal/output-limit/tool/usage semantics
remain the existing reducer and admission contracts.

The fixed Sinal event and stage/provider/outcome fields remain. Because HTTP
Gun's consumer API exposes the response head rather than a wire-submission
callback, `request_sent` is observed at the head with outcome
`http_response_started`. It must not be used as an exact submission timestamp.
Prepared, progress, terminal, cancellation, deadline and cleanup observations
remain under LLM Wire's semantic owner.

## Client configuration and fixtures

The old LLM pool, connector, HTTP cassette codec and production Gun FFI are
removed. `config.with_pool` and per-call CA setters no longer exist. Set
`http_gun/config.CustomCa(path)` at client startup; certificate and hostname
verification apply, including for application-approved remote private CAs.
LLM Wire still admits plaintext only for loopback. HTTP Gun's default
destination policy refuses loopback and private addresses, so a client for a
local or private-network model server sets `destination.Policy` with
`allow_loopback` or `allow_private` at startup. The old idle-connection
eviction setting has no HTTP Gun equivalent and is removed, not ignored.

Scripts, strict offline playback and actual live recording all supply the same
client capability. LLM testing helpers are pure reply/exchange builders. Current
HTTP Gun binary fixtures retain significant request headers, query and body;
only its documented credential metadata names are excluded. There is no request
history server, duplicate codec, old-schema fallback or network fallback.
Repeated identical exchanges consume distinct replies sequentially. Mismatch
leaves the next exchange intact. Concurrent order-sensitive work must coordinate
admission explicitly; identical concurrent requests in the consumer example
intentionally have identical replies.

Recording capture bounds and publication errors are independent of HTTP and
semantic success. Finalization waits for consumed/closed requests without
draining. Replacement policy is explicit. Body/query redaction and power-loss
durability are optional application/dependency features, not migration promises.

## Validation scope

[Validation receipts](http-gun-validation.md) cover built-in and custom providers,
signed Google turns, tool/structured workflows, failure races, real recording,
H1/TLS/H2, external consumers and practical concurrency on the recorded runtime.
Released unmodified Gun/Cowlib remain transitive dependencies. Protocol parser
hardening, universal memory/performance certification, other runtimes and public
provider conformance are outside these measured claims.
