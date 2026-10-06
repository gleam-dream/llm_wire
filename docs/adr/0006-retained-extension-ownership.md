# Retain advanced capability scope without hiding new lifecycles

<a id="adr-0006"></a>

## Decision and alternatives

- The source design retains provider-native options, tool modes/choice, model metadata, hosted-tool outcomes, richer content/reasoning, audio/video, embeddings, realtime, batch/background work, interrupted-stream resumption and optional remote cancellation acknowledgement. Their absence from the initial consumer is neither implemented support nor permanent rejection.
- Keep advanced provider meaning at a typed adapter boundary and application policy with the caller. A universal raw-options map can overwrite admitted model/tool/schema/stream settings; a hidden agent loop overlaps Fabric and conceals retry/effect authority, so neither is adopted here.
- A complete custom adapter currently supplies both encoder and reducer. A narrow built-in native option could reduce that burden, but replacing the extension contract without a concrete advanced consumer would speculate about maintenance and validation costs.
- Local SSE close cannot acknowledge remote rollback. Realtime, resumed or background interactions require explicit states, identifiers, compatibility, budgets and cleanup contracts rather than inheriting one-request semantics implicitly.

## Evidence and status

- This is retained intent from the [full source design](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/llm-design.md) and its [coverage matrix](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/API-COVERAGE.md). Native pending entries expose unbuilt/unspecified contracts; this capture does not accept proposed signatures.
- An illustrative reasoning-effort request was raised during source review, but no retained consumer proves a blocked production workload or measured quality/latency benefit. A future offline consumer should compare a narrow provider option with a safely admitted request extension while retaining existing decoder/schema/tool guarantees.
- These unresolved choices have no invented retrospective acceptance date. Optional model catalog freshness and provider-native option provenance remain their owner's responsibility.
