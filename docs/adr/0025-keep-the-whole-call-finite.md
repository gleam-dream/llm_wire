# Keep the whole call finite

<a id="adr-0025"></a>

## Decision

- HTTP Gun gives every request a finite timeout, 30 seconds unless the call sets another, and no longer offers an unbounded one. Generation already replaces that timeout with its whole-call budget, so a stream or a long generation runs on its own budget rather than the client's 30 second default.
- The whole-call budget and the classification request timeout are therefore always finite: each is set as a duration, and `Infinity` no longer applies to them. An unbounded whole call could only be honoured by silently inheriting the client's default, which would cut long streams, or by inventing a large stand-in, which would be unbounded in all but name.
- First-token and idle-gap timers belong to the semantic owner, not to HTTP Gun, and keep `Infinity`. A caller that wants a long call chooses a long budget.

## Evidence and limits

- Local streaming cases run a stream past a 100 ms request timeout set on the client's view, and the separate consumer checks that the view's timeout is replaced while an explicit client deadline remains a ceiling under a long call budget.
- Transcription borrows the client unchanged by design, so its request runs under the client view's timeout, 30 seconds by default; a caller transcribing long audio sets a longer timeout on the view it passes.
