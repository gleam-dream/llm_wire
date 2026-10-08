# Public LLM Wire consumer

This is a separate package using the actual `../..` LLM Wire checkout and the
local HTTP Gun and Blueprint siblings, and only their public modules. Run it
from the LLM Wire root with `nix develop -c sh test/external_package_boundary.sh`.
The gate also compiles a second positive consumer and checks that forbidden
uses of the API fail with the intended compiler errors.

`src/llm_wire_consumer.gleam` reads top to bottom as the API is learned:

1. the common path: `openai.new(key) |> openai.config`, `llm_wire.request`,
   `llm_wire.prepare`, `llm_wire.run`, then `Answer` or
   `llm_wire.describe_failure`;
2. structured output with `llm_wire.with_output(name, codec)`: the `Answer`
   holds the decoded value, and `error.InvalidOutput` keeps the raw text;
3. a tool round trip: on `NeedsTools`, decode each call with
   `tool.decode_arguments`, append `message.Assistant(turn)` and one
   `llm_wire.tool_result` per call, and prepare the next request;
4. streaming with `llm_wire.stream` and `llm_wire.next` until `Done`;
5. retry decisions with `llm_wire.advise`: LLM Wire never retries, so the
   application bounds attempts and uses one monotonic deadline for calls and
   waits; an unaffordable provider delay returns the original failure;
6. a custom adapter built with `llm_wire/provider`, whose key lives only in
   its header closure.

`main` runs each of them offline: `testing.events_for(message.OpenAI, reply)`
lowers a scripted reply into OpenAI's own wire, so the real OpenAI
configuration runs against an `http_gun/testing` playback client.

The application owns the shared client's entire lifetime. `http_child`
supervises it under a name with `http_gun.supervised`, and `http_client`
reaches it with `http_gun.named`, so the handle stays valid across restarts.
`flow` runs one buffered call, one early-closed stream and ten concurrent calls
on any client; `main` runs it with a script and again from the script's
cassette. The `live` and `record` constructors compile but are not invoked
here, preventing an accidental provider call. Real local recording of text,
tool-result and structured workflows is exercised by
`test/llm_wire_recording_test.gleam` in the parent package.

The twelve scripted exchanges of `flow` have identical replies deliberately.
For distinct replies to identical concurrent requests, coordinate admission
order explicitly. The example uses HTTP Gun's default configuration: each LLM
call's own timeouts replace the client's request timeout.

`run_with_retries` admits positive attempts and a total budget of
1–4,294,967,295 whole milliseconds (the BEAM receive timeout range). Fallback
backoff cannot be negative. It uses public `stream`, `next_within` and `close`
because a prepared call already captures its original timeouts. The same
deadline survives retries and progress events; provider delays are never
shortened to fit. Attempt exhaustion and unaffordable waits preserve the
original `Failure` in `ProviderFailure`.

`RetryDeadlineReached` means local work was stopped; it does not prove that the
provider cancelled or avoided charging tokens. Startup retains its runtime
bound; this helper does not preempt synchronous custom callbacks.
Read-timeout arbitration can take up
to five additional seconds, and close allows up to five seconds before killing
the owner. The budget bounds admitted execution and waiting, not an exact
return-time ceiling including cleanup. The helper owns each stream; the caller
continues to own the shared HTTP client.

`retry_checks` uses strict offline playback to check excessive provider delays,
cumulative waiting, attempt exhaustion, affordable retry and invalid policy.
`test/retry_deadline.py` runs `retry_deadline_checks` against a temporary loopback
HTTP server: an infinite-timeout call is closed at the application deadline,
and time spent in a failed call prevents an unaffordable fallback retry. The
fixture checks request counts, HTTP closure and released body/queue counters.
These checks run in the external-package boundary command above.

`classification_consumer` exercises `classify.typesafe()` with separate live
settings, then an independent array-based provider using typed question views
and answer candidates. It retains application-native labels in a heterogeneous
batch, handles absent confidence and usage, configures custom headers and byte
limits, checks invalid evidence, and round-trips durable receipts offline.
The main consumer runs it as part of the full gate.
