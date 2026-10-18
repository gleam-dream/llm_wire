# Agent Instructions

## About this repo

- `llm_wire` is an independent typed, bounded LLM wire and streaming library for Gleam on Erlang/OTP. The application owns conversation history, retry, tool execution and the shared HTTP Gun client.
- The design layer under `docs/design/` owns architecture and behavior, each context's `CONTEXT.typ` owns its vocabulary, and `docs/adr/` owns decisions. Read the pending ledgers before treating behavior conflicts or deferred scope as resolved.
- Verify facade changes (common use, advanced configuration, caller-native types, failure handling) from the separate consumer in `examples/consumer/` using public imports.
- HTTP Gun, Blueprint and Sinal are Git dependencies of unpublished packages. `manifest.toml` holds their resolved commits, and nothing updates them automatically: run `gleam update <package>` by hand when a change is needed. Trust and transport policy belong to the application-owned HTTP client; a dependency checkout stays read-only unless the task explicitly includes it.

## Commands

- `nix develop` or direnv provides Gleam, Erlang/OTP 29, rebar3 and local-check tools. `nix fmt` formats the repository, lefthook formats and restages staged files, and `nix flake check` includes the formatting gate.
- Fast gate: `nix develop -c sh dev/gate fast` (formatting, build warnings, public module docs, production HTTP boundaries, unit and local H1/TLS cases).
- Full gate: `nix develop -c sh dev/gate full` adds a clean build, the external consumers (`nix develop -c sh test/external_package_boundary.sh`) and the nghttpd H2 and concurrency harness (`python3 dev/local-http.py`).
- Gates use offline and local inputs. `nix develop -c sh dev/record-live [scenario]` is an opt-in operation that spends provider tokens and needs explicit task authorization; never inspect or copy credential values.
- After editing `docs/design/`, run the design-gate commands from the fenced block below sequentially.
- Usage lives as compiled, offline examples in `examples/consumer/src/` (the full gate runs them). When a public API changes, update the matching `usage_*` example and the README block that `dev/readme_example_test.py` checks against `readme_call.gleam`.

## References

- [docs/ORACLE.md](docs/ORACLE.md) pins the upstream implementations (ReqLLM v1.24.0, `anthropic_gleam` 0.1.1, protocol documentation) whose selected behavior the tests compare against, and records the selected cases, exclusions and limits. Update it when a pin or a compared case changes.
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md) records the finite local HTTP measurement (method, environment, dated results and limits). It sets no speed ceiling; never turn a number from it into a gate.
- The two documents cross-link, and both point to the design's Observability and verification section and to ADRs 0005 and 0015.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(machine-owned; do not edit inside this fence — re-run setup to refresh)

## Agent skills

**Design layer** — `docs/CONTEXT-MAP.md` indexes the design documents.
`docs/design/design.typ` is the root design; the `generation`,
`classification` and `transcription` contexts each have a
`docs/design/<context>/design.typ` and a `docs/design/<context>/CONTEXT.typ`
that defines their vocabulary. `docs/adr/` records decision rationale. The
layer renders to one document, `docs/design/design-layer.pdf`.
`docs/COVERAGE.md` maps repository parts to their design owners.

**Tracker** — local markdown under `issues/`: one directory per feature
(`issues/<feature-slug>/`), the PRD at `issues/<feature-slug>/PRD.md`, issue
files at `issues/<feature-slug>/issues/<NN>-<slug>.md` numbered from 01. Each
issue file carries two header lines near the top — `Status: <state>`,
`Category: <category>`. Conversation appends to the bottom
of the file under a `## Comments` heading. Labels (canonical strings, adopted
verbatim): states `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `in-progress`, `done`, `wontfix`; categories `bug`,
`enhancement`.

**AI disclaimer** — AI-authored tracker comments start with
`AI-assisted contribution.`

**Design gate** — `nix run .#design-gate-check -- docs/design .` checks render freshness,
vocabulary references and layer integrity (exit 0 clean, 1 violation, 2 error).
The gate is supplied by the pinned `design-layer` flake input.
`nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`
rebuilds the rendered document. `nix run .#design-gate-context -- docs/design --estimate`
estimates agent context; the same command without `--estimate` emits ephemeral
Markdown. `--manifest`, `--preview`, and `--section PATH --expect-digest DIGEST`
support loading selected sections. A bare Typst compilation does not run the gate.

**Context verification** — use native semantic blocks for lists, tables,
models and behavior. After authoring, verify context estimation and a selected
section export as well as rendering and the design gate.
Run these commands sequentially for each layer; they share its generated
`.render` workspace.

**Staleness** — source changes since the design last changed require a
conformance review before the layer is treated as current.

<!-- agent-skills:end -->
