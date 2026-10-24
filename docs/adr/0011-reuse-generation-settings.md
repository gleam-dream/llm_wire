# Reuse generation settings independently of requests

<a id="adr-0011"></a>

## Decision

On 16 October 2026 the owner approved a reusable immutable generation-settings
value. Existing request setters and the new value share one representation.
The custom provider request retains its existing field labels as a derived view.
Validation remains at preparation, where the selected provider is known.

## Rationale and alternatives

Fabric assembles transcripts, tools and output contracts. A raw request callback
would give applications authority to overwrite those values. A settings value
exposes the missing generation controls without that authority. Mirrored Fabric
setters would duplicate the provider vocabulary and its maintenance.

Full replacement gives with_generation a deterministic composition rule.
Individual setters can then override one control. Defaults retain absent values;
provider-specific defaults remain with the provider encoder.
