# Qualify unpublished sibling changes through an explicit local-source capture

<a id="adr-0014"></a>

## Decision and alternatives

- Ordinary builds resolve the Git dependencies locked in the manifests, so editing a sibling checkout changes nothing. A coordinated change to an unpublished sibling is qualified only through Oversight's explicit whole-graph local-source capture, which copies and normalizes the complete sibling graph and records its source hashes.
- The capture does not qualify the locked Git sources, and the ordinary gate does not run it. Path dependencies in the manifests were rejected as a default because they make a clean checkout unreproducible.

## Evidence and limits

- The capture runs from the [Oversight repository](https://github.com/gleam-dream/oversight) with its `scripts/local_sources.py`; consumers then run inside the captured graph through the original Nix shell.
