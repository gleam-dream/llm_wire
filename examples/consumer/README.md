# Public LLM Wire consumer

This is a separate package using the actual `../..` LLM Wire checkout and the
local HTTP Gun sibling, rather than HTTP Gun's archived LLM example. Run from
the LLM Wire root with `nix develop -c sh test/external_package_boundary.sh`.
The gate compiles a second positive provider/schema/telemetry consumer and
checks the intended errors for forbidden APIs.

`src/llm_wire_consumer.gleam` contains compilable buffered execution, streamed
early close, ten concurrent independent calls, application supervision and
live/script/playback/recording startup. `main` executes the same `flow` with
scripts and strict offline playback. The live and recording constructors compile
but are not invoked here, preventing an accidental provider call. Real local
recording of text, tool-result and structured workflows is exercised by
`test/llm_wire_recording_test.gleam` in the parent package.

The application owns the shared client's entire lifetime. `http_child` uses
`http_gun.child` and `supervision.map_data` to publish each newly started client;
the application must route calls to that capability after a restart. Requests
remain independently prepared, and a single call never stops the client.

The twelve scripted exchanges consist of one buffered call, one early-closed
stream and ten simultaneous calls. Their replies are identical deliberately.
For distinct replies to identical concurrent requests, coordinate admission
order explicitly. The example sets a 120-second client ceiling so HTTP Gun's
default 30-second ceiling does not truncate the default 60-second LLM budget.
