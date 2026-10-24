# Leave stream read authority an open owner ruling

<a id="adr-0007"></a>

## Decision and alternatives

- Stream's public comment says only the creating process may read, while [owner.handle_next](https://github.com/gleam-dream/llm_wire/blob/4726271d1671f48fe63222bc2133af1aacfe60e9/src/llm_wire/internal/owner.gleam) accepts another process and serializes pending reads. The creator still owns lifetime through monitoring.
- Restricting reader authority and documenting transferred reads are distinct alternatives. The design layer records the conflict in its pending ledger and does not choose a side, because the owner's intended authority is unresolved and a passing design gate does not approve a semantic correction.
- Both alternatives keep one pending read per stream and creator-owned lifetime. Only the set of processes allowed to read differs.

## Evidence and limits

- The owner tests and the separate consumer exercise copied handles, conflicting reads and creator death; they do not settle which authority the public contract promises.
- A second conflict found in the same review, the retry consumer sleeping a provider delay without a total budget, was resolved separately by [ADR-0012](0012-bound-the-retry-consumer.md). An attempt count alone does not bound total waiting, and a caller-owned remaining budget does.
- A disposable separate-consumer run against strict offline playback reported the main assertions passing at revision 4726271d1671f48fe63222bc2133af1aacfe60e9. That transient copy is not a retained oracle; the checked-in consumers and owner tests are the reproducible inputs.
