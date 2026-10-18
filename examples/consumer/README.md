# Public LLM Wire consumer

A separate package that depends on the parent `llm_wire` checkout through public imports only, with HTTP Gun, Blueprint and Sinal pinned in its manifest. Every example runs offline against scripted HTTP Gun playback and contacts no provider. The examples are the usage documentation: they compile and run in the full gate, so they stay current with the library.

## Run

From the LLM Wire root:

```sh
nix develop -c sh test/external_package_boundary.sh
```

The command builds this package with warnings as errors, runs `gleam run` (every example below), then compiles a second positive consumer and checks that forbidden uses of the API fail with the intended compiler errors. Run one example with `gleam run -m <module>` in this directory. For unpublished sibling changes, capture the sibling graph first as described in [ADR-0014](../../docs/adr/0014-qualify-unpublished-siblings-by-local-source-capture.md).

## Usage by topic

| Topic                                                                                                                                           | Module in `src/`                                                                                                                 |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| The first call, as in the [README](../../README.md#make-a-call)                                                                                 | `readme_call.gleam` (compiled; checked against the README by `dev/readme_example_test.py`)                                       |
| Defaults, timeouts and limits                                                                                                                   | `usage_defaults.gleam`                                                                                                           |
| Text, structured output, tool rounds, streaming, retry advice, custom provider, client supervision, early close, concurrency, cassette playback | `llm_wire_consumer.gleam`                                                                                                        |
| Tools, conversation history and turn persistence                                                                                                | `usage_conversation.gleam`                                                                                                       |
| Failures, retry advice and error kinds                                                                                                          | `usage_failures.gleam`                                                                                                           |
| Retry with one application deadline                                                                                                             | `retry_checks.gleam`, `retry_deadline_checks.gleam` (the second runs against a loopback server, `test/retry_deadline.py`)        |
| An explicit client deadline                                                                                                                     | `deadline_checks.gleam`, `deadline_http_checks.gleam` (the second runs against a loopback server, `test/generation_deadline.py`) |
| Reusable generation settings                                                                                                                    | `generation_checks.gleam`                                                                                                        |
| Own the HTTP client                                                                                                                             | `usage_client.gleam`                                                                                                             |
| Testing without a network                                                                                                                       | `usage_testing.gleam`                                                                                                            |
| Observing calls with Sinal                                                                                                                      | `usage_observe.gleam`                                                                                                            |
| Classification                                                                                                                                  | `classification_consumer.gleam`                                                                                                  |
| Inline audio transcription                                                                                                                      | `transcription_consumer.gleam`                                                                                                   |

The design layer owns the contracts these files exercise; start from [Observability and verification](../../docs/design/design.typ). Oracle and benchmark references are in [ORACLE.md](../../docs/ORACLE.md) and [BENCHMARKS.md](../../docs/BENCHMARKS.md).
