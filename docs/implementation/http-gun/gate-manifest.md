# Local validation profiles

The migration specification and `docs/http-gun-migration.md` authorize these
checks. LLM Wire owns both profiles. The pre-migration repository had separate
commands but no `dev/gate`. Run inside the pinned Nix shell with the local HTTP
Gun, Blueprint and Sinal siblings present. Temporary external consumers inherit the checked-in consumer lock closure, with
absolute local paths. Negative probes use Gleam's `compile-package --no-beam`
build-tool API against that compiled closure, with a valid control before the
intentional errors; positive consumers use normal check/run commands. Siblings are compiled as dependencies;
their source checkouts are never changed. No provider endpoints are used.

| Obligation                                                                           | Measuring command                                                                 | Profile                             | Strength                                                       |
| ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------- | ----------------------------------- | -------------------------------------------------------------- |
| Repository formatting                                                                | `treefmt --fail-on-change`, `gleam format --check src test examples/consumer/src` | fast/full                           | mechanism                                                      |
| Compiler and public types                                                            | `gleam check`, `gleam build --warnings-as-errors`                                 | fast/full; full first cleans output | mechanism                                                      |
| Handwritten test bridge warnings                                                     | `erlc -Werror +warn_unused_vars +warn_unused_function -o TEMP test/*.erl`         | fast/full                           | mechanism; production has no handwritten FFI                   |
| One documented HTTP boundary                                                         | forbidden-import/name audit in `dev/gate`; source review                          | fast/full                           | partial; names alone do not prove ownership                    |
| Observable provider/session/fixture behavior                                         | `gleam test`                                                                      | fast/full                           | partial; named regression scenarios, not universal conformance |
| Actual external adoption and opacity                                                 | `sh test/external_package_boundary.sh`                                            | full                                | mechanism for named positive and negative consumers            |
| Verified TLS H2, sibling cancellation, simultaneous callers and sampled resource use | `python3 dev/local-http.py`                                                       | full                                | partial; local nghttpd and bounded workload                    |
| Patch whitespace                                                                     | `git diff --check`                                                                | fast/full                           | mechanism                                                      |

Exact entry points: `nix develop -c sh dev/gate fast` and
`nix develop -c sh dev/gate full`. Existing `nix fmt` and `nix flake check`
retain their meanings. Receipts, including failing regression witnesses, are in
`docs/evidence/http-gun/`; the validation report identifies the accepted runs.

Only the measured Darwin ARM64 OTP 28 runtime is claimed by this migration.
There is no hosted CI or schedule in this local-dependency repository. A registry
dependency layout, hosted CI, additional OS/OTP matrix, exhaustive provider
conformance, dependency parser memory certification and long-running soak are
unmeasured, not silent passing checks. Reuse this entry point when CI is added.
