# Record unpublished changes in ADRs and the design instead of a changelog

<a id="adr-0016"></a>

## Decision and alternatives

- The package has no published release, so it keeps no changelog. Present behavior lives in the design layer and the reasoning for each change lives in an ADR; a release-notes file begins with the first published version.
- A changelog of unreleased entries was rejected because it restated the design as a second narrative and claimed release history that does not exist.

## Evidence

- The removed changelog listed these capabilities, each now owned elsewhere: inline transcription ([ADR-0009](0009-bounded-inline-transcription.md)), reusable generation settings ([ADR-0011](0011-reuse-generation-settings.md)), preserved application deadlines ([ADR-0010](0010-preserve-application-deadlines.md)), the bounded retry consumer ([ADR-0012](0012-bound-the-retry-consumer.md)), one generic generation family ([ADR-0003](0003-one-generic-generation-family.md)), caller-owned history ([ADR-0001](0001-caller-owned-conversations.md)), classification ([ADR-0008](0008-pure-classification-protocols.md)) and offline qualification ([ADR-0013](0013-qualify-with-offline-replay-and-a-public-consumer.md)).
