#import "../.render/designlib.typ": *
#import "CONTEXT.typ": accent

#let title = [Transcription]

#let body = [
  #section(title: "Foundation", lead: "One inline audio request returns completed text while the caller keeps transport and recovery policy.", body: [
    #goal(title: "Return completed text from inline audio")[A caller turns bounded inline audio into a nonempty native String through one Google Interactions request.]
    #no-goal(title: "Manage audio resources or recovery")[Uploads, diarization, timestamps, custom vocabulary, streaming audio, persistence, duplicate protection and retry stay outside this contract.]
    #invariant(title: "Only completed well-formed text succeeds", enforcement: "mechanism")[A truncated, incomplete, empty or malformed response never yields partial text.]
    #invariant(title: "Preparation performs no I/O", enforcement: "mechanism")[Audio admission and request encoding allocate and validate locally; headers stay behind an inspection-safe closure.]
    #principle(title: "Leave transport authority with the caller")[The supplied HTTP client keeps its limits, deadline, cancellation, trust and destinations. The operation adds no retry and no client lifetime.]
  ])

  #pending-ledger(
    pending-entry(title: "Accept the inline transcription implementation", kind: "ruling", since: "2026-10-09", adr: [#adr(9)])[
      The contract is specified and implemented. The owner has not yet accepted the delivered implementation.
    ],
  )

  #section(title: "Transcription", lead: "One inline audio request returns completed text while the caller keeps transport and recovery policy.", body: [
    #answers(title: "Inline transcription", responsibility: [Admit inline bytes, encode one Google Interactions request and return completed nonempty text.], interface: [transcribe.audio validates bytes and MIME under the caller's raw byte allowance; settings(model) defaults to automatic language detection and Verbatim. google(key) creates Config, with_endpoint and with_request_limit configure it, prepare returns opaque Prepared, request_json exposes only its body, and run(client, prepared) returns String or the common Failure.], interactions: [The application supplies model, language hints, mode and its existing HTTP Gun client. It may place the returned String in its own record or a later generation request.], invariants: [Preparation performs no I/O. Encoded headers remain behind a closure. Execution neither retries nor changes the client's policy or lifetime.], failure: [AudioError distinguishes invalid bytes, unsupported MIME, invalid allowance and excess raw bytes. Preparation returns PrepareError. Executed failure retains provider and conservative send evidence.])
    #entity(id: "transcription-audio", title: "Inline audio", description: [Nonempty byte-aligned audio declared by the caller.], kind: "value-object", owner: "transcription admission", lifecycle: "immutable", domain: "transcription")[
      #attribute(name: "Bytes and MIME", type: "BitArray and admitted MIME String", provenance: "authored")[The constructor bounds raw bytes before Base64 encoding. It admits the provider's documented WAV, MP3, AIFF, AAC, OGG, FLAC, MPEG, M4A, L16, Opus, ALAW, MULAW and WebM MIME strings. It does not inspect codecs, duration or acoustic validity.]
      #attribute(name: "Allowance", type: "positive byte count", provenance: "authored")[The caller owns allocation of the original input. Admission cannot retroactively bound that allocation.]
    ]
    #entity(id: "prepared-transcription", title: "Prepared transcription", description: [One admitted encoded inline request, reusable only by explicit caller choice.], kind: "value-object", owner: "transcription admission", lifecycle: "immutable", domain: "transcription")[
      #attribute(name: "Input and settings", type: "encoded request body and endpoint", provenance: "derived")[Settings keeps a required nonempty model, language-code strings and Verbatim or Smart. Empty language hints mean provider autodetection; provider/model compatibility is checked remotely. The request sets store to false.]
      #attribute(name: "Credentials", type: "inspection-safe header closure", provenance: "derived")[Preparation validates and captures a nonempty visible-ASCII API key. Changing credentials requires preparing again. request_json contains audio data and is sensitive even though it excludes credentials.]
      #relates(cardinality: "1 : 0..n")[A prepared value can be executed repeatedly. It is not an idempotency receipt or a durable execution record.]
    ]
    #points(
      [The default endpoint is the Google HTTPS Interactions endpoint. Overrides are complete HTTPS URLs with a nonempty host/path and no userinfo, query, fragment or controls. Client destination/TLS policy still applies. Request JSON is limited after encoding, by default to 16 MiB; with_request_limit changes that positive allowance. Raw admission, encoded admission and HTTP response bounds protect different allocations.],
      [run borrows the client unchanged: response byte/overflow bounds, absolute deadline, timeout, cancellation, trust and destinations remain the caller's. A truncated buffered result is always refused. This family adds no first-token timer, SSE owner or universal memory guarantee. JSON depth is checked before decoding; synchronous encoding/decoding has no independent preemption.],
      [Only a completed response with well-formed model-output text produces a nonempty trimmed String. Text fragments retain order; reasoning and other typed content are excluded. Malformed text refuses the whole result; incomplete, empty, invalid UTF-8 or invalid JSON are protocol failures.],
      [A non-success response retains status and Retry-After with no response body. A transport failure preserves the HTTP failure and NotSent or MaybeSent; a complete unusable response has Completed evidence. Truncation has MaybeSent evidence and never yields partial text. Failure.partial_output is false because this operation emits no progress.],
      [Started, buffered RequestSent, Terminal and Cleanup observations reuse the package event and caller correlation. They contain no audio, key or transcript. Cleanup describes local transport, not remote cancellation.],
      [File upload, remote resource management, diarization, timestamps, custom vocabulary, streaming audio, persistence, duplicate protection and retry are outside this contract. These remain caller or explicitly deferred capabilities. #adr(9) explains the separate family.],
    )
    #behavior(title: "Invalid audio or configuration is refused before execution", area: "Transcription admission", level: "interface")[
      #given[Audio is empty, misaligned, oversized or has an unsupported MIME, or its preparation has invalid credentials, request settings or encoded allowance.]
      #when[The caller constructs the audio or prepares it.]
      #then[A typed refusal identifies the input boundary and no execution starts.]
    ]
    #behavior(title: "Only completed usable transcription becomes text", area: "Transcription result", level: "interface")[
      #given[A prepared inline transcription receives a completed provider response.]
      #when[The response is interpreted.]
      #then[Well-formed model text returns as one ordered trimmed nonempty String; unusable or incomplete evidence returns a typed failure.]
    ]
    #behavior(title: "Transcription preserves caller transport authority", area: "Transcription execution", level: "boundary")[
      #given[The caller executes a prepared transcription through its configured transport view.]
      #when[The request succeeds, fails, is cancelled, exceeds a bound or returns truncated data.]
      #then[One attempt preserves that view's restrictions, closes its response and leaves the shared client usable.]
      #then[Truncated data is refused and no automatic retry or remote rollback is claimed.]
    ]
  ])
]
