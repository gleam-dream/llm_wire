# Bound the retry consumer with an application deadline

<a id="adr-0012"></a>

## Decision

- On 2026-10-07 the user approved correcting the retry teaching example with TDD, including both execution and waiting in a finite budget. This resolves only the retry item from [ADR-0007](0007-preserve-observed-contract-gaps.md); stream read authority remains unresolved.
- The application uses `stream`, `next_within` and `close` because a prepared interaction already captures its configured call timeout. A monotonic deadline limits each read and governs retry admission without changing the core API or spawning an unowned worker.
- Provider delays are minimum waits. An unaffordable delay returns the original failure; shortening that delay to fit would violate provider advice. Attempt exhaustion also returns the provider failure.
- Deadline and read failures use application error variants rather than fabricating provider identity, usage or send evidence. Closing local work does not establish remote cancellation.
- The execution budget excludes cancellation acknowledgement and cleanup. The runtime allows up to five seconds for pending-read arbitration and up to five seconds for close before killing its owner. Startup and synchronous custom callbacks retain their existing contract. An exact wall-clock return deadline would require a different resource and execution boundary.

## Evidence

- The separate public consumer retains offline playback regressions and a local HTTP deadline fixture. These do not call a live model provider or establish arbitrary extension callback preemption.
