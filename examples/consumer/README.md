# Public LLM Wire consumer

[![CI](https://github.com/gleam-dream/llm_wire/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/gleam-dream/llm_wire/actions/workflows/ci.yml)
[![llm_wire on Hex](https://img.shields.io/hexpm/v/llm_wire?label=Hex%3A%20llm_wire)](https://hex.pm/packages/llm_wire)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A separate package using only public imports from the parent `llm_wire` checkout,
with HTTP Gun, Blueprint and Sinal pinned in its manifest. Its offline flows use
scripted HTTP Gun playback and run in the full gate. The standalone
`readme_call` module is a compiled live-provider example; running it separately
requires provider credentials and network access.

## Run

From the LLM Wire root:

```sh
nix develop -c sh test/external_package_boundary.sh
```

The command builds this package with warnings as errors, runs `gleam run` (the offline example flows below), then compiles a second positive consumer and checks that forbidden uses of the API fail with the intended compiler errors. Run one example with `gleam run -m <module>` in this directory. For unpublished sibling changes, capture the sibling graph first as described in [ADR-0014](../../docs/adr/0014-qualify-unpublished-siblings-by-local-source-capture.md).

## Usage by topic

| Topic                                                                                                                                           | Module in `src/`                                                                                                                 |
| ----------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| Standalone live-provider call                                                                                                                   | `readme_call.gleam` (compiled; a live-provider entrypoint run separately)                                                        |
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

The design layer owns the contracts these files exercise; start from [Observability and verification](../../docs/design/design-layer.pdf). Oracle and benchmark references are in [ORACLE.md](../../docs/ORACLE.md) and [BENCHMARKS.md](../../docs/BENCHMARKS.md).
