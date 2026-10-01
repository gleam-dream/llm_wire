# Agent Instructions

## About this repo

`llm_wire` — A strongly typed, bounded LLM wire and streaming client for Gleam on Erlang/OTP.

Local accepted ownership: [caller-owned conversations](docs/caller-owned-conversation.md) and
[HTTP Gun migration](docs/http-gun-migration.md) supersede older continuation, pool
and cassette descriptions. HTTP Gun and other siblings remain read-only.

Parent design: [gleam-dream/oversight](https://github.com/gleam-dream/oversight)/llm-design.md.

## Tooling

- `nix develop` (or direnv): dev shell with `gleam`, Erlang/OTP 28, `rebar3`, `lefthook`.
- `nix fmt`: formats the whole repo via treefmt (`gleam format`, `nixfmt`, `prettier`).
- `lefthook`: pre-commit hook formats staged files and re-stages them.
- `nix flake check`: fails iff the tree is not formatted (plus any existing checks).
- `gleam test`: runs the test suite.

- `nix develop -c sh dev/gate fast`: formatting, compiler/build, test FFI warnings,
  production HTTP boundary audit and complete unit/local H1/TLS suite.
- `nix develop -c sh dev/gate full`: clean build plus fast checks, actual external
  consumers and local nghttpd H2/concurrency validation. No provider credentials
  or public provider calls. Details: `docs/implementation/http-gun/gate-manifest.md`.
- Local dependencies require sibling `http_gun`, `json_blueprint` and `sinal`
  checkouts. Trust/transport policy belongs to an application-owned HTTP Gun client.
