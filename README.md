# llm_wire

LLM calls and streaming for Gleam on Erlang/OTP, with typed answers, tool requests
and failures. Built-in adapters support OpenAI Responses, Anthropic Messages and
Google GenerateContent; custom adapters use the same execution API. Classification
and inline audio transcription are separate request families.

## Install

This checkout is an unreleased 0.1.0 candidate for Gleam 1.18 or newer. Gleam
fetches its pinned Git dependencies. For local development, add a Wire checkout
and the matching HTTP Gun revision to your application:

```toml
[dependencies]
llm_wire = { path = "../llm_wire" }
http_gun = { git = "https://github.com/gleam-dream/http_gun.git", ref = "e4f00b8525e20a7b568b2cd585fe4e37db161b26" }
```

Adjust the Wire path to your workspace. The package targets Erlang; the pinned Nix
shell uses OTP 29.

## Make a call

Replace the example key with one supplied by your application and choose a model
available to that account.

```gleam
import gleam/io
import http_gun
import http_gun/config as http_config
import llm_wire
import llm_wire/error
import llm_wire/openai

pub fn main() -> Nil {
  let config = openai.new("sk-...") |> openai.config
  let request = llm_wire.request("gpt-5", [llm_wire.user("Hello")])
  case llm_wire.prepare(config, request) {
    Error(problem) -> io.println(error.describe_prepare_error(problem))
    Ok(prepared) ->
      case http_gun.start(http_config.default()) {
        Error(problem) -> io.println(http_gun.describe_start_error(problem))
        Ok(client) -> {
          let result = llm_wire.run(client, prepared)
          http_gun.stop(client)
          case result {
            Ok(llm_wire.Answer(text:, ..)) -> io.println(text)
            Ok(_) -> io.println("no final answer")
            Error(failure) -> io.println(llm_wire.describe_failure(failure))
          }
        }
      }
  }
}
```

`prepare` validates and encodes the request without I/O. `run` returns after the
response stream is closed. The application owns the HTTP client, conversation
history, tool execution and retries; a long-running application can supervise one
shared client with `http_gun.supervised`.

Generation defaults to a 600-second whole-call timeout, 180 seconds to first
semantic progress and a 60-second idle gap after that progress. Byte and queue
limits are finite. The [design](docs/design/generation/design.typ) lists every
default and how the timers compose with HTTP Gun.

## Usage

Structured output changes only the request: `llm_wire.with_output("invoice",
invoice_codec)` makes `Answer` carry the decoded value, and unusable text returns
`error.InvalidOutput` with the raw text. A tool round trip declares tools with
`llm_wire.with_tools`, decodes each call with `tool.decode_arguments` when `run`
returns `NeedsTools`, and appends `message.Assistant(turn)` and one
`llm_wire.tool_result` per call to the next request. `llm_wire.stream` and
`llm_wire.next` deliver progress until `Done`, and `llm_wire.advise` turns a
failure into retry advice without scheduling anything.

The [public consumer](examples/consumer/README.md) is the usage documentation:
compiled, offline programs that run in the full gate, one per topic.

| Topic                                                                       | Example                                                                          |
| --------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| First call (the block above)                                                | [`readme_call`](examples/consumer/src/readme_call.gleam)                         |
| Defaults, timeouts and limits                                               | [`usage_defaults`](examples/consumer/src/usage_defaults.gleam)                   |
| Text, structured output, tool rounds, streaming, retries, a custom provider | [`llm_wire_consumer`](examples/consumer/src/llm_wire_consumer.gleam)             |
| Tools, history and turn persistence                                         | [`usage_conversation`](examples/consumer/src/usage_conversation.gleam)           |
| Failures and retry advice                                                   | [`usage_failures`](examples/consumer/src/usage_failures.gleam)                   |
| Own the HTTP client                                                         | [`usage_client`](examples/consumer/src/usage_client.gleam)                       |
| Test without a network                                                      | [`usage_testing`](examples/consumer/src/usage_testing.gleam)                     |
| Observe calls                                                               | [`usage_observe`](examples/consumer/src/usage_observe.gleam)                     |
| Classification                                                              | [`classification_consumer`](examples/consumer/src/classification_consumer.gleam) |
| Audio transcription                                                         | [`transcription_consumer`](examples/consumer/src/transcription_consumer.gleam)   |

## References

[Oracle references](docs/ORACLE.md) pin the upstream implementations whose
selected behavior the tests compare against, and [benchmarks](docs/BENCHMARKS.md)
records the finite local HTTP measurement and its limits. The design layer owns
the contracts: [overview](docs/design/design.typ),
[vocabulary](docs/design/generation/CONTEXT.typ), [decisions](docs/adr/) and the
[coverage map](docs/COVERAGE.md).

## Development

Run from this directory inside the pinned Nix shell:

```sh
nix develop -c sh dev/gate fast
nix develop -c sh test/external_package_boundary.sh
```

`AGENTS.md` lists the full gate, formatting and design-gate commands. Provider
recording is opt-in and needs explicit authorization.
