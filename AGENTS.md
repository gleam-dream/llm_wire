# Agent Instructions

## About this repo

- `llm_wire` is an independent typed, bounded LLM wire and streaming library for Gleam on Erlang/OTP. The application owns conversation history, retry, tool execution and the shared HTTP Gun client.
- [Native design](docs/design/design.typ) owns architecture and behavior; [CONTEXT](docs/design/CONTEXT.typ) owns vocabulary; [ADRs](docs/adr/) own decisions. Read the pending ledger before treating behavior conflicts or deferred scope as resolved.
- Read the organization's public API guidelines before proposing a facade change. Verify common use, advanced configuration, caller-native types and failure handling from the separate consumer using public imports.
- HTTP Gun, Blueprint and Sinal are local sibling dependencies. Trust/transport policy belongs to the application-owned HTTP client; a dependency checkout remains read-only unless the task explicitly includes it.

## Tooling

- `nix develop` or direnv provides Gleam, Erlang/OTP 28, rebar3 and local-check tools. `nix fmt` formats the repository; lefthook formats and restages staged files; `nix flake check` includes the formatting gate.
- `nix develop -c sh dev/gate fast` checks formatting/build warnings, public module docs, production HTTP boundaries and unit/local H1/TLS cases. Full adds clean build, external consumers and nghttpd H2/concurrency checks; details live in [testing guidance](docs/testing.md).
- Normal gates use offline/local inputs. `dev/record-live` is an opt-in token-spending operation requiring explicit task authorization; never inspect or copy credential values while doing documentation work.
- Render/check the native layer with the pinned design-gate apps. Use the repository Git flake URL after installation so ignored render/build artifacts do not enter a path snapshot.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(machine-owned; do not edit inside this fence — re-run setup to refresh)

## Agent skills

**Design layer** — `docs/design/design.typ` describes the design,
`docs/design/CONTEXT.typ` defines its vocabulary, and `docs/adr/` records
decision rationale. The rendered document is `docs/design/design-layer.pdf`.
`docs/COVERAGE.md` maps repository parts to their design owners.

**Tracker** — GitHub issues in `gleam-dream/llm_wire`, accessed with
`gh issue list --repo gleam-dream/llm_wire` and `gh issue view NUMBER --repo gleam-dream/llm_wire`.
Labels bind roles as follows: `needs-triage` → `needs-triage`,
`needs-info` → `question`, `ready-for-agent` → `ready-for-agent`,
`ready-for-human` → `ready-for-human`, `in-progress` → `in-progress`,
`done` → `done`, `wontfix` → `wontfix`, `bug` → `bug`,
and `enhancement` → `enhancement`.

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
