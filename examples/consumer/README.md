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
   application waits the advised delay and runs the same prepared call again;
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
