# Use one generic generation family and typed retry evidence

<a id="adr-0003"></a>

## Decision and alternatives

- The release API redesign uses Request(o), Prepared(o), Stream(o), Outcome(o) and Event(o) for both text and native structured output. with_output changes the request's output type; separate structured execution twins were redundant unpublished APIs.
- Opaque admitted values keep raw HTTP and captured state out of callers. Keys remain inside closures; common limits use one named Limit setter; typed preparation/execution errors separate local refusal from runtime failure.
- Invalid structured output is a typed failure with raw text, validation reason, Completed evidence and usage. Treating it as a success outcome would add an unusable branch to ordinary text consumers; discarding raw output would prevent caller review/recovery.
- Failure carries its provider and conservative sent/progress evidence, so advise needs no duplicated provider argument. ProviderDelay distinguishes provider Retry-After from caller Backoff; scheduling and budgets remain caller-owned, and the provider delay stays uncapped for durable schedulers.
- Three semantic timers replace the earlier idle window covering hidden reasoning: whole call 600 s, first semantic progress 180 s, then event idle 60 s. Usage alone does not end first-progress waiting; the 1 MiB line bound handles provider events repeating complete final text.

## Evidence

- [177ad50](https://github.com/gleam-dream/llm_wire/commit/177ad5062b3d53e4653e95f90452ff527fe3fdf2) implements the generation facade; [e809711](https://github.com/gleam-dream/llm_wire/commit/e8097115948c3b9cdde580067c9d2c491d641cbd) and [2c32d5e](https://github.com/gleam-dream/llm_wire/commit/2c32d5eb9325d8689cadce5075a615c350708254) establish retry delay meaning.
- The originating [release review](https://github.com/gleam-dream/oversight/blob/3baff7030a96d5b6cf78b2335c16d8c203727da5/docs/release-api/llm_wire.md) records the duplicate families, timeout composition and long SSE line defects. Current facade, timers, advise, long-line, secret-redaction and external consumers are retained executable evidence.
- This record consolidates unreleased facade/round migration rationale; historical test counts are not fresh validation results.
