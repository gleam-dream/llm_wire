#import "../.render/designlib.typ": *
#import "CONTEXT.typ": accent

#let title = [Classification]

#let body = [
  #section(title: "Foundation", lead: "A classification returns native answers whose evidence reconstructs without live settings.", body: [
    #goal(title: "Return native classification answers")[Typed questions yield application-native values, full distributions and optional confidence and usage from one bounded buffered request, independent of any one provider's envelope.]
    #goal(title: "Reconstruct decisions from stored evidence")[A durable operation rebuilds a native outcome from its saved receipt through a pure wire, without credentials or a provider call.]
    #no-goal(title: "Own operation storage or approval")[The caller owns operation versions, the enclosing record's bound, approval and recovery. Classification owns no checkpoint or retry runtime.]
    #invariant(title: "Malformed evidence never becomes a native outcome", enforcement: "mechanism")[Shared admission rejects missing, duplicate or unknown question ids, wrong answer kinds, incomplete distributions and inconsistent native evidence before constructing an outcome.]
    #invariant(title: "Wires and receipts hold no live settings", enforcement: "mechanism")[A pure wire and its receipt codec capture encoding, decoding and fixed bounds only. Credentials, endpoint overrides and live byte policy belong to live configuration.]
    #principle(title: "Separate pure protocol from live operation", lens: "composition")[A wire is fixed for an operation version while fresh live configuration is obtained after approval or restart. Absent measurements stay absent.]
  ])

  #pending-ledger(
    pending-entry(title: "Check carried-over classification bounds against code", kind: "verify", since: "2026-10-17", adr: [#adr(17)])[
      The receipt bounds and the admission limits came from retired guides. The classification consumer exercises live admission and durable reconstruction. The numeric bounds and the evidence-failure cases are not yet checked against code.
    ],
  )

  #section(title: "Classification", lead: "Typed questions use pure protocol adapters and shared evidence validation.", body: [
    #subsection(title: "Question and candidate model")[
      #entity(id: "question-batch", title: "Question batch", description: [The typed classification definition owned by the application.], kind: "value-object", owner: "classification questions", lifecycle: "immutable", domain: "classification")[
        #attribute(name: "Definitions", type: "unique question ids and QuestionView values", provenance: "authored")[YesProbability has instructions and optional yes/no criteria; Choice has labeled alternatives; Score has ordered rubric levels. Native alternative values stay private to the batch.]
        #attribute(name: "Native decoder", type: "candidate admission to a", provenance: "derived")[ask names one question; combine creates a heterogeneous tuple answer. Source constructors panic on definition bugs; runtime check constructors return InvalidDefinition.]
      ]
      #entity(id: "classification-wire", title: "Classification wire", description: [A protocol fixed independently of live operation settings.], kind: "value-object", owner: "wire author", lifecycle: "immutable", domain: "classification")[
        #attribute(name: "Projection", type: "provider, endpoint, pure encoder/decoder", provenance: "authored")[Encoder consumes model/state and typed question views; decoder returns resolved model, candidates and optional usage. The wire must not capture credentials.]
        #attribute(name: "Receipt bounds", type: "positive request and response bytes", provenance: "authored")[Each defaults to 1 MiB and governs stable retained evidence.]
      ]
      #entity(id: "classification-outcome", title: "Classification outcome", description: [A validated native answer plus its reproducible evidence.], kind: "value-object", owner: "classification runtime", lifecycle: "immutable", domain: "classification")[
        #attribute(name: "Native result", type: "a and optional Usage", provenance: "derived")[Choice keeps selected value/label, full native probabilities and optional confidence. Score keeps weighted position, ordered probabilities, rubric and optional confidence. Noul keeps yes probability.]
        #attribute(name: "Evidence", type: "requested/resolved model, state, request JSON and response JSON", provenance: "observed")[This material supports pure reconstruction; it contains no live authentication or HTTP process.]
      ]
      #points(
        [Question instructions/state content is text, object or array validated under JSON structural/numeric limits; choice descriptions may explicitly be null. Ids/labels are nonempty, trimmed only for the emptiness check. Batches contain at most 256 unique questions, choices 2 through 255 alternatives, scores 2 through 10 levels.],
        [The candidate sum is Yes(yes), Selected(label, probabilities, confidence) or Rated(position, indexed probabilities, levels, confidence). Exact question ids/kinds and exact distribution keys are checked, including duplicates. Probabilities are finite in 0 through 1 and sum to one within 0.00001.],
        [A selected choice must be a known label and maximal within 0.00001. Returned probabilities are reordered to authored alternative order and retain each application value even when several labels map to the same value. A score's canonical rubric must match; its position is in 0 through levels minus one and matches the weighted distribution within 0.00001 times level count.],
        [Present confidence must be within 0 through 1; absent #term("term-concentration-evidence") remains None. Missing usage is None, and reported counts must be nonnegative. TypeSafe's protocol still requires its mandatory confidence/usage fields; shared optionality does not make malformed mandatory evidence absent.],
        [Shared parsing uses the already admitted byte allowance while retaining Blueprint's depth, value-count and numeric-token limits. TypeSafe validates precise decimal bounds before Float conversion and rejects positive underflow to zero. Custom wires own their corresponding precise-number and mandatory-field checks. #adr(8) records this extension boundary.],
      )
      #behavior(title: "Malformed candidates cannot bypass shared admission", area: "Classification evidence", level: "boundary")[
        #given[A wire returns missing, duplicate or unknown ids, wrong kinds, incomplete probabilities or inconsistent native evidence.]
        #when[Classification decodes its candidate answer.]
        #then[It rejects the answer as a typed validation error instead of constructing a native outcome.]
      ]
      #behavior(title: "Optional measurements preserve absence", area: "Classification evidence", level: "interface")[
        #given[A wire permits absent confidence or usage and returns complete valid answer evidence.]
        #when[Classification admits the response.]
        #then[The native outcome preserves missing measurements as None.]
        #then[Malformed evidence required by the wire remains a failure.]
      ]
    ]
    #subsection(title: "Live admission and execution")[
      #answers(title: "Classification execution", responsibility: [Prepare one typed decision request and execute one bounded buffered HTTP exchange.], interface: [typesafe or wire produces Wire; config(reveal) produces live Config; prepare(wire, config, request) returns Prepared(a); run(client, prepared) returns Outcome(a) or Failure.], interactions: [The caller supplies state, questions, HTTP client and fresh live settings. TypeSafe System One is a built-in wire; other wires can use unrelated envelopes.], invariants: [Wire/receipt decoding never acquires live auth; preparation checks live/receipt compatibility before revealing credentials. Live byte allowances cannot exceed fixed receipt bounds.], failure: [PrepareError names setting/unsupported question/content errors; run returns the common typed Failure with wire provider identity and conservative send evidence.])
      #md-table(3, (
        [*Boundary*], [*Effect*], [*Time and capacity*],
        [prepare], [pure wire encode and bounded JSON validation; default bearer key validation after pure admission], [positive live limits at most fixed receipt limits; endpoint/model/timeout valid],
        [custom headers], [replace bearer auth; unused bearer closure is not invoked], [header reveal occurs when building the HTTP request for execution],
        [run], [fresh call id/correlation; HTTP send buffers response under response limit], [600 s default request timeout; Infinity explicit; HTTP client idle/connect/pool policies remain],
        [response], [UTF-8 check, status, bounded JSON, wire decode, candidate admission], [non-200 status has empty retained body and optional Retry-After; response body limit still applies],
        [success], [Outcome includes native answer and original request/response/state], [no tool loop, SSE stream or generation first-progress/idle timers],
      ))
      #points(
        [Live Config holds auth, optional endpoint override, timeout and live request/response bytes, each defaulting to 1 MiB. The pure wire is fixed separately; a Fabric operation/version owns that choice while providing fresh live configuration after approval/recovery. No Fabric type is needed in LLM Wire.],
        [Default bearer reveal validates visible ASCII/nonempty after pure admission and is invoked again at HTTP request construction; auth freshness is a caller callback property. with_headers replaces it without revealing or validating the unused key. HTTP Gun remains responsible for admitting the resulting request.],
        [Classification endpoint validation admits HTTPS or loopback HTTP and requires a nonempty path with no userinfo/query/fragment/controls. Plaintext execution uses the same destination setup described under Execution ownership. It replaces request timeout and body limit; it does not lift HTTP idle as generation does.],
        [The classification timer is HTTP Gun's buffered send budget. Synchronous auth callbacks before send and JSON/native decoding after send have no independent preemption; it is not a wall-clock guarantee over arbitrary callbacks. A successful HTTP response with unusable evidence has Completed send evidence, partial_output False and no failure usage retained by current failure_for.],
      )
      #md-table(3, (
        [*Classification bound*], [*Default*], [*Owner of the change*],
        [Whole request timeout], [600 seconds, or an explicit Infinity], [Live config],
        [Request JSON and response JSON], [1 MiB each], [Live config, at most the wire's receipt bounds],
        [Receipt request and response JSON], [1 MiB each], [The wire],
        [Questions per batch], [256], [Fixed],
        [Choice alternatives and score levels], [2 through 255 and 2 through 10], [Fixed],
      ))
      #points([Raising a byte allowance does not raise Blueprint's structural limits (nesting 64, 262,144 values and bounded number tokens). The HTTP client's own request, buffering and collection limits are independent and can impose a smaller allowance. A call neither retries nor follows redirects, and keys enter only through a reveal closure.])
      #behavior(title: "Receipt limits are checked before credentials", area: "Classification preparation", level: "interface")[
        #given[A live byte allowance is nonpositive or exceeds the wire's fixed receipt allowance.]
        #when[The caller prepares classification.]
        #then[Preparation returns InvalidSetting for that limit.]
        #then[No credential closure is invoked and no provider request occurs.]
      ]
    ]
    #subsection(title: "Durable receipt reconstruction")[
      #answers(title: "Classification receipt codec", responsibility: [Reconstruct a native answer solely from saved protocol evidence.], interface: [receipt_codec(wire, questions) is a Blueprint Codec(Outcome(a)) with no schema; supports the llm.classification.receipt.v1 and fabric.typesafe.receipt.v1 tags.], interactions: [The embedding store versions its operation/wire and separately bounds the enclosing record, including escaping and state.], invariants: [The reconstructed request equals saved request canonically and response candidates satisfy the same authored questions. Encoding rejects forged native outcomes.], failure: [Wrong format, oversized evidence, changed questions or inconsistent response/native answer fails codec encoding/decoding; no credentials or provider call is used.])
      #points(
        [The array tag llm.classification.receipt.v1 carries requested model, state, request JSON and response JSON. The tag fabric.typesafe.receipt.v1 contains request and response only; model and state are recovered from the bounded request. Both follow the same reconstruction.],
        [Restoration bounds saved request/response, re-encodes expected questions/model/state under fixed wire bounds, parses and canonicalizes object member order, compares saved/expected requests, decodes/admit response and constructs native Outcome. Encoding additionally compares the reconstructed outcome with the supplied outcome.],
        [Wire identity/projections and receipt bounds are compatibility facts of the embedding operation version. Live endpoint, key and smaller live limits may change without making old receipts unreadable. Raising evidence allowance requires explicitly raising fixed receipt and live allowances; the outer storage record still needs its own bound. #adr(8) records why these policies stay distinct.],
      )
      #behavior(title: "Receipt decoding is independent of live settings", area: "Receipts", level: "boundary")[
        #given[A saved receipt uses the fixed wire/questions and compatible bounded evidence.]
        #when[Its receipt codec decodes it.]
        #then[It reconstructs the native answer and retained evidence without live configuration, credentials or I/O.]
      ]
      #behavior(title: "Changed evidence refuses durable reconstruction", area: "Receipts", level: "boundary")[
        #given[A saved request disagrees with deployed questions or a native outcome disagrees with its protocol evidence.]
        #when[The codec decodes the receipt or encodes that outcome.]
        #then[It returns a typed codec failure instead of accepting the inconsistent record.]
      ]
    ]
  ])
]
