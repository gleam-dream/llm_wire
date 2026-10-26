# Agent Instructions

## About this repo

- `llm_wire` is an independent typed, bounded LLM wire and streaming library for Gleam on Erlang/OTP. The application owns conversation history, retry, tool execution and the shared HTTP Gun client.
- The design layer under `docs/design/` owns architecture and behavior, each context's `CONTEXT.typ` owns its vocabulary, and `docs/adr/` owns decisions. Read the pending ledgers before treating behavior conflicts or deferred scope as resolved.
- Verify facade changes (common use, advanced configuration, caller-native types, failure handling) from the separate consumer in `examples/consumer/` using public imports.
- HTTP Gun, JSON Blueprint and Sinal use Hex version requirements. Each `manifest.toml` holds the resolved versions; update them with `gleam deps update <package>` when needed. Trust and transport policy belong to the application-owned HTTP client; a dependency checkout stays read-only unless the task explicitly includes it.

## Commands

- When updating dependency pins, reconcile affected `manifest.toml` files in examples, consumers and nested packages through Gleam, then run the full repository gate; updating the root lock alone is insufficient.

- `nix develop` or direnv provides Gleam, Erlang/OTP 29, rebar3 and local-check tools. `nix fmt` formats the repository, lefthook formats and restages staged files, and `nix flake check` includes the formatting gate.
- Fast gate: `nix develop -c sh dev/gate fast` (build warnings, unit and local H1/TLS cases).
- Full gate: `nix develop -c sh dev/gate full` adds a clean build, the external consumers (`nix develop -c sh test/external_package_boundary.sh`) and the nghttpd H2 and concurrency harness (`python3 dev/local-http.py`).
- Gates use offline and local inputs. `nix develop -c sh dev/record-live [scenario]` is an opt-in operation that spends provider tokens and needs explicit task authorization; never inspect or copy credential values.
- After design changes, render and run the imported design check.
- Usage lives as compiled, offline examples in `examples/consumer/src/` (the full gate runs them). When a public API changes, update the matching `usage_*` example; README code excerpts are synchronized from tested sources with Snips.

## References

- [docs/ORACLE.md](docs/ORACLE.md) pins the upstream implementations (ReqLLM v1.24.0, `anthropic_gleam` 0.1.1, protocol documentation) whose selected behavior the tests compare against, and records the selected cases, exclusions and limits. Update it when a pin or a compared case changes.
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md) records the finite local HTTP measurement (method, environment, dated results and limits). It sets no speed ceiling; never turn a number from it into a gate.
- The two documents cross-link, and both point to the design's Observability and verification section and to ADRs 0005 and 0015.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(Validation policy updated by the owner on 2026-10-20.)

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

**Shared validation** — `nix fmt` owns formatting; `nix flake check` checks it.
`nix run .#design-gate-check -- docs/design .` runs the imported design check.
CI invokes these checks directly. `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`
renders the layer; `nix run .#design-gate-context -- docs/design --estimate`
estimates context. Review documentation and conventions manually.

**Staleness** — source changes since the design last changed require a
conformance review before the layer is treated as current.

<!-- agent-skills:end -->

## README snippets

Keep README Gleam examples in compiled example or consumer source. Use named
`snips-start` / `snips-end` regions (or include a whole example module), and retain
Prettier ignore ranges around generated README blocks. Format the source first,
then run `nix run .#snips -- --commands deny README.md`. CI runs
`nix run .#snips -- --check --commands deny README.md` using the shared pinned
package. Snips checks synchronization; existing example tests check behavior.

## Commit messages

Use a concise subject and an optional explanatory body. Do not add any commit
footers or trailers, including `Co-authored-by`, `Signed-off-by`, `Reviewed-by`,
`Acked-by`, or tool/AI attribution. Do not use `git commit --signoff` or let an
automated tool append a footer. Tracker-comment attribution rules apply only to
tracker comments, never to commit messages.
