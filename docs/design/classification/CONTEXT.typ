#let accent = "violet"

#let terms = (
  (slug: "term-classification-wire", title: [Classification wire], body: [A pure provider protocol projection with its identity, default endpoint and fixed receipt evidence bounds. Its lifetime is independent of live execution settings.]),
  (slug: "term-classification-config", title: [Classification config], body: [Live settings holding fresh credentials, an optional endpoint override, a timeout and live byte allowances. It selects no wire.]),
  (slug: "term-question-batch", title: [Question batch], body: [Named classification questions retaining application-native values and a decoder for their combined answer. Heterogeneous batches combine their native answers as tuples.]),
  (slug: "term-answer-candidate", title: [Answer candidate], body: [An untrusted provider-neutral yes probability, selected choice or rated rubric emitted by a classification wire. Shared admission determines whether it matches the authored questions.]),
  (slug: "term-receipt-bounds", title: [Receipt bounds], body: [The fixed request and response byte allowances of a wire that govern stored evidence. Live byte allowances cannot exceed them.]),
  (slug: "term-classification-receipt", title: [Classification receipt], body: [The requested model, state and original request and response evidence from which a native classification outcome is reconstructed. Its codec captures a pure wire and questions rather than live credentials.]),
  (slug: "term-concentration-evidence", title: [Concentration evidence], body: [An optional provider-reported confidence measurement of the answer distribution. It is not the probability that the answer is correct.]),
)
