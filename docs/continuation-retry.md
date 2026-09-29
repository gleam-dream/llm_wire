# Superseded continuation checkpoint proposal

The owner replaced the unpublished checkpoint design on 2026-09-29. Agent
continuation and persistence belong to Fabric. The implementation and tests for
wire-owned continuation handles, source binding, checkpoint encoding/restoration,
and replay codecs were removed before release.

The accepted replacement is [caller-owned conversation and cassette playback](caller-owned-conversation.md).
[Fabric migration notes](fabric-migration.md) describe the downstream work.

The independent retry assessment remains: `retry.assess(provider, error)` returns
`MayHelp`, `WillNotHelpUnchanged`, or `Unknown`. It never schedules a retry. The
caller considers reachability, progress, effects, deadlines and budgets before
choosing another attempt.
