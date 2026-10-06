# llm_wire

LLM calls and streaming for Gleam on Erlang/OTP, with typed answers, tool requests
and failures. Built-in adapters support OpenAI Responses, Anthropic Messages and
Google GenerateContent; custom adapters use the same execution API.

## Install

This checkout is an unreleased 0.1.0 candidate for Gleam 1.18 or newer. Place
`http_gun`, `json_blueprint` and `sinal` checkouts beside `llm_wire`, then add the
paths from your application's directory:

```toml
[dependencies]
llm_wire = { path = "../llm_wire" }
http_gun = { path = "../http_gun" }
```

Adjust those paths to your workspace. The package targets Erlang; the pinned Nix
shell uses OTP 28.

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
limits are finite. See the [defaults and setters](docs/usage.md#defaults) for the
complete list and how these timers compose with HTTP Gun.

## More usage

The [usage guide](docs/usage.md) covers tools and conversation codecs, structured
output, classification, streaming, retry advice, custom providers, offline tests
and telemetry. The [separate consumer](examples/consumer/README.md) provides
complete runnable examples using public imports, including application-native
values and client supervision.

[Local benchmark results](docs/benchmarks.md) retain measured H2 latency and
resource observations with their workload, source and runtime details.

## Development

Run from this directory with the sibling checkouts present:

```sh
nix develop -c sh dev/gate fast
nix develop -c sh test/external_package_boundary.sh
```

[Testing guidance](docs/testing.md) covers the full local gate, formatting and
opt-in provider recording. [Native design](docs/design/design.typ),
[rendered design](docs/design/design-layer.pdf) and [decision records](docs/adr/)
describe ownership and unresolved contracts. The [coverage map](docs/COVERAGE.md)
locates each design owner.
