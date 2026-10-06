# Expose behavior conflicts instead of documenting them as resolved

<a id="adr-0007"></a>

## Evidence and proposed corrections

- At revision 4726271d1671f48fe63222bc2133af1aacfe60e9, [the retry consumer](https://github.com/gleam-dream/llm_wire/blob/4726271d1671f48fe63222bc2133af1aacfe60e9/examples/consumer/src/llm_wire_consumer.gleam) sleeps ProviderDelay directly. The [public delay contract](https://github.com/gleam-dream/llm_wire/blob/4726271d1671f48fe63222bc2133af1aacfe60e9/src/llm_wire.gleam) explicitly requires callers to bound it; an attempt count alone does not bound total waiting.
- The proposed example correction is a caller-owned remaining wait budget: when a requested provider delay exceeds it, return the original typed failure rather than retry earlier. A total operation deadline also needs execution-time accounting; no runtime/example change is accepted or implemented by this documentation capture.
- Stream's public comment says only the creator may read, while [owner.handle_next](https://github.com/gleam-dream/llm_wire/blob/4726271d1671f48fe63222bc2133af1aacfe60e9/src/llm_wire/internal/owner.gleam) accepts another process and serializes pending reads. The creator still owns lifetime through monitoring. Restricting reader authority and documenting transferred reads are distinct alternatives; the owner's intended authority is unresolved.
- A prior disposable separate-consumer run against strict offline playback reported the existing main assertions passing. Its transient copy is not a retained oracle and did not prove the proposed retry budget or settle read authority; the checked-in consumers and owner tests remain the reproducible evidence inputs.
- Native pending entries preserve both conflicts. A passing design gate does not approve a semantic correction.
