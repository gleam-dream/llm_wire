#let accent = "teal"

#let terms = (
  (slug: "term-inline-audio", title: [Inline audio], body: [Nonempty byte-aligned audio with an admitted MIME string, bounded by the caller's raw byte allowance before Base64 encoding. Admission does not inspect codec, duration or acoustic validity.]),
  (slug: "term-prepared-transcription", title: [Prepared transcription], body: [One admitted encoded inline request with its endpoint and inspection-safe headers. It is reusable by explicit caller choice and is neither an idempotency receipt nor a durable record.]),
  (slug: "term-transcription-mode", title: [Transcription mode], body: [The typed choice between Verbatim and Smart output for one request. Language support remains a provider decision.]),
)
