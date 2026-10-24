# Preserve explicit application deadlines

<a id="adr-0010"></a>

## Decision

- On 2026-10-16 the user approved preserving an explicit deadline on a borrowed HTTP client during generation. A relative client default can be replaced by the generation budget; an absolute application deadline cannot be extended by the library.
- Generation retains one absolute whole-call deadline across setup and dispatch. HTTP opening receives its remaining duration as a relative timeout so HTTP Gun can enforce the earlier application deadline.
- Keeping the replacement absolute deadline would let an inner operation exceed its caller's budget. Adding a second public deadline option would duplicate HTTP Gun's existing ownership contract.

## Evidence and limits

- The separate consumer reproduces refusal before submission and checks that the expected scripted exchange remains usable through the original client. Local streaming cases check both deadline orders, an infinite whole-call bound, replacement of a relative default and response cleanup.
- Expiry establishes local termination without proving provider rollback. Synchronous extension callbacks and terminal cleanup retain their existing bounds; this decision adds no callback preemption or exact return-time guarantee.
