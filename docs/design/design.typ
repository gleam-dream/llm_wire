#import ".render/designlib.typ": *

#let title = [LLM Wire]
#let index_only = true

#let body = [
  #section(title: "Foundation", lead: "Independent provider interactions compose with a caller-owned application.", body: [
    #goal(title: "Return typed bounded provider interactions")[Direct callers and agent runtimes prepare and execute one provider interaction (generation, classification or transcription) without acquiring a tool loop, workflow checkpoint or persistence runtime.]
    #no-goal(title: "Own conversations or application effects")[The caller owns history, tool execution, authorization, approvals, retries, round budgets, durable recovery and duplicate-effect protection.]
    #no-goal(title: "Duplicate the generic HTTP runtime")[HTTP Gun owns connection and body lifetime, TLS, destination admission, pooling, byte transport and HTTP recording and playback.]
    #invariant(title: "Unknown evidence remains unknown", enforcement: "mechanism")[Absent usage and optional classification confidence remain None. Local cancellation proves neither provider rollback nor cancellation acknowledgement.]
    #principle(title: "State each lifecycle's own contract")[A protocol with a different lifetime states its own limits, ownership and failure evidence instead of inheriting another family's guarantees by name.]
  ])

  #pending-ledger(
    pending-entry(title: "Establish upstream allocation guarantees", kind: "verify", since: "2026-10-06", adr: [#adr(2)])[
      Package byte and queue bounds do not prove a strict pre-allocation bound for complete HTTP header blocks in Gun and Cowlib, native JSON allocation or arbitrary custom reducer state. HTTP parser hardening requires dependency evidence or a transport decision; no second parser and no universal memory guarantee is introduced.
    ],
    pending-entry(title: "Broaden provider and runtime conformance evidence", kind: "verify", since: "2026-10-06", adr: [#adr(5)])[
      Selected local protocol, OTP, TLS and H2 cases and recorded provider cases do not establish exhaustive provider parity, every offered model, other runtime combinations or long-running soak. A new classification wire needs its own protocol and replay evidence.
    ],
  )

  #section(title: "System at a glance", lead: "Generation, classification and transcription keep distinct models within one library.", visual: diagram(
    altitude: "L1", viewpoint: "context-ownership", title: "Authorities around one provider interaction",
    groups: ((id: "wire", label: "LLM Wire", kind: "domain", tint: "slate"), (id: "external", label: "External authorities", kind: "domain", tint: "slate")),
    nodes: (
      (id: "app", label: "Application / Fabric", sub: "history, policy, effects", kind: "external-system", group: "external"),
      (id: "generation", label: "Generation", sub: "admission and semantic stream", kind: "bounded-context", group: "wire", tint: "blue"),
      (id: "classification", label: "Classification", sub: "questions and evidence", kind: "bounded-context", group: "wire", tint: "violet"),
      (id: "transcription", label: "Transcription", sub: "inline audio to text", kind: "bounded-context", group: "wire", tint: "teal"),
      (id: "http", label: "HTTP Gun", sub: "HTTP resource authority", kind: "external-system", group: "external"),
      (id: "provider", label: "Remote provider", sub: "remote work authority", kind: "external-system", group: "external"),
      (id: "blueprint", label: "Blueprint", sub: "schema and exact JSON values", kind: "external-system", group: "external"),
      (id: "sinal", label: "Sinal", sub: "observations", kind: "external-system", group: "external"),
    ),
    edges: (
      (from: "app", to: "generation", relation: "call", label: "prepared generation"),
      (from: "app", to: "classification", relation: "call", label: "prepared classification"),
      (from: "generation", to: "http", relation: "call", label: "owned response scope"),
      (from: "classification", to: "http", relation: "call", label: "bounded buffered send"),
      (from: "app", to: "transcription", relation: "call", label: "prepared transcription"),
      (from: "transcription", to: "http", relation: "call", label: "borrowed buffered send"),
      (from: "transcription", to: "sinal", relation: "pubsub", label: "lifecycle facts"),
      (from: "http", to: "provider", relation: "dataflow", label: "request / response"),
      (from: "generation", to: "blueprint", relation: "dependency", label: "schema admission"),
      (from: "classification", to: "blueprint", relation: "dependency", label: "numeric evidence"),
      (from: "generation", to: "sinal", relation: "pubsub", label: "lifecycle facts"),
      (from: "classification", to: "sinal", relation: "pubsub", label: "lifecycle facts"),
    ),
    caption: [The application supplies its HTTP client to each family. No runtime dependency on Fabric, Saga, Relay or Grind exists.],
  ), body: [
    #points(
      [Generation owns request admission, configured provider encoding, semantic SSE reduction, streaming delivery and normalized outcomes. Classification owns authored questions, candidate validation and pure durable evidence decoding. Transcription owns inline audio admission and terminal text decoding through the same caller-owned HTTP authority.],
      [The whole model follows: request values are prepared without execution; generation creates a #term("term-stream-owner"); terminal response values return to the caller. A #term("term-classification-receipt") reconstructs classification values without restarting an operation.],
      [The package has no published release. Present behavior lives in this design layer and the reasoning behind each change lives in the ADRs (#adr(16)).],
      [Gleam on Erlang/OTP is the execution platform. The JavaScript target is unsupported. The dependency boundaries and separation from agent state follow #adr(1) and #adr(2).],
    )
    #md-table(3, (
      [*Context*], [*Owned model*], [*Units*],
      [#ctx("generation")], [Config, Request(o), Prepared(o), Stream(o), Outcome(o), tool declaration, assistant turn, Failure], [Generation admission, caller-owned conversation, provider interpretation, execution ownership, failure and retry evidence],
      [#ctx("classification")], [Wire, live Config, Batch(a), candidates, Outcome(a), receipt], [Question and candidate model, live admission and execution, durable receipt reconstruction],
      [#ctx("transcription")], [Audio, Settings, Config, Prepared, nonempty text], [Inline admission, inline protocol, borrowed buffered exchange],
      [Root], [Observation, semantic replies, HTTP exchanges, cassettes], [Observability and verification, extension boundaries, end-to-end walkthrough],
    ))
    #points([Classification and transcription use the Failure, #term("term-send-evidence") and observation vocabulary that #ctx("generation") owns, and conform to it.])
  ])

  #section(title: "Observability and verification", lead: "Tests exercise real reducer paths while observations report bounded lifecycle facts.", body: [
    #subsection(title: "Observation contract")[
      #answers(title: "LLM observation", responsibility: [Report execution facts without transferring authority to observers.], interface: [telemetry.event() is Sinal's llm_wire/observation event; Metadata holds call, correlation, stage, provider and outcome.], interactions: [The execution copies correlation from the supplied HTTP Gun view so HTTP and LLM events join once.], invariants: [A retry gets a fresh call id. Content, credentials, arguments and status bodies are absent from telemetry.], failure: [Observation does not replace terminal state or authorize retry. Synchronous observer runtime behavior belongs to Sinal and the embedding application.])
      #points(
        [Stages are Started, RequestSent, FirstProgress, Terminal, Cancelled, Deadline and Cleanup. RequestSent marks arrival of the response head with http_response_started, not an exact network submission timestamp. Classification's buffered path emits that stage after send returns.],
        [Generation emits semantic owner facts; classification and transcription emit Started, buffered response, Terminal and Cleanup. prepare emits nothing. End-to-end latency measurement surrounds execution rather than subtracting a fabricated send timestamp.],
      )
    ]
    #subsection(title: "Validation profiles")[
      #md-table(4, (
        [*Check*], [*Fast*], [*Full*], [*Establishes*],
        [Tree and Gleam formatting], [yes], [yes], [Declared formatting],
        [Gleam check and build with warnings as errors], [yes], [clean build], [Public types and compiler checks],
        [Authored Erlang bridges with warnings as errors], [yes], [yes], [Independent native FFI compilation],
        [Production boundary and public module-doc audit], [yes], [yes], [Named forbidden paths and documentation presence],
        [Gleam and classifier Python tests], [yes], [yes], [Named semantic, local H1, TLS and server cases],
        [External positive and negative consumers], [no], [yes], [Public adoption and intended opacity errors],
        [Usage examples in the public consumer], [format], [build and run], [Documented usage compiles and runs against the current public API (#adr(17))],
        [README first call against the compiled example], [yes], [yes], [The README block equals the compiled example],
        [Local nghttpd H2 and concurrency harness], [no], [yes], [Finite local trust, isolation and resource observations],
        [Workflow, shell and Python lint and gate counterexamples], [yes], [yes], [Authored tooling and failed evidence rejection],
        [Git diff whitespace], [yes], [yes], [Patch whitespace],
      ))
      #points(
        [Gates run in the pinned Nix shell against the immutable dependency revisions in the manifests. Formatting is checked on a copied Nix tree, so a gate never repairs the working tree. Frozen request fixtures, cassettes, oracle provenance, retained evidence and generated output are excluded from automatic formatting. A passing gate log is evidence for its recorded revision and runtime only.],
        [Gates use local and offline inputs. Static checks never execute the live recorder or read its credential source. Compiler flags reject warnings; runtime fault reports remain runtime evidence.],
        [CI runs the full gate on every push, pull request, manual run and weekly schedule. A final job rejects failed, cancelled and skipped mandatory jobs. The weekly run records finite HTTP observations without a latency ceiling. Sibling dependency revisions come from one pinned list, are checked out without persisted credentials, and fork pull requests run the same checks.],
        [Exported source copies record an unavailable Git revision and dirty state as null; the enclosing consumer receipt owns source identity. Lockfile hashes and runtime identity are still captured. Changes to unpublished siblings are qualified by an explicit whole-graph local-source capture that records its source hashes and does not qualify the immutable Git baseline (#adr(14)).],
      )
    ]
    #subsection(title: "Offline qualification")[
      #points(
        [The #term("term-public-consumer") is also the usage documentation: one compiled, offline program per topic (defaults and limits, conversation and persistence, failures and retry advice, testing helpers, observation and client ownership) beside the flows below, with no prose usage guide to drift (#adr(17)). It exercises text, native structured output, tool rounds, streaming, retry advice, a custom provider, client supervision, early close, concurrency and script and cassette playback through public imports only. Its classification consumer proves an independent array envelope, native labels, heterogeneous questions, custom authentication and limits, absent measurements and receipts. Its transcription consumer proves common preparation, custom endpoint, model, language and mode, native result records and status failures. Negative compiler fixtures prove that opaque values stay opaque, using a positive compiled control so a missing dependency does not impersonate an intended type error.],
        [Reusable-settings checks exercise each provider, source-compatible custom provider fields, native output and replay, setter precedence and typed preparation refusal before extension callbacks. Deadline checks cover refusal before submission, both deadline orders, an infinite whole-call timeout, replacement of a relative default, retained failure evidence, closure of timed-out sockets and zero body and queue counters before the borrowed client is reused. Retry checks cover excessive provider delay, cumulative waiting, attempt exhaustion, affordable retry and invalid policy, and a loopback server proves that active-call time consumes the same deadline.],
        [Unit and reducer suites cover strict schema, output and tool admission, routing, fragmentation, usage, malformed events and semantic bounds. Owner and HTTP suites cover copied handles, conflicts, timed-read races, caller and owner death, pre-header close, absolute deadlines, slow readers and terminal-before-EOF. Local H1, TLS and H2 checks cover trust, reuse and sibling isolation under finite workloads.],
        [Production has no handwritten Erlang FFI; test bridges provide TCP, clocks and resource measurements. These are verification mechanisms rather than proof of universal conformance.],
      )
    ]
    #subsection(title: "Local HTTP measurement")[
      #points(
        [A harness measures finite simultaneous demand (1, 10, 100 and 1,000 callers on one verified H2 connection to a local nghttpd) and the isolation of a cancelled stream from a sibling that collects its full response. The workload, method, recorded environment, dated results and limits are in #lnk("../BENCHMARKS.md")[the benchmarks reference].],
        [Acceptance checks semantic results, one H2 connection and cancellation isolation; timing has no speed ceiling. A run writes a fresh receipt directory recording source and sibling revisions with dirty flags, lockfile hashes, runtime and OS versions, raw consumer output and a bounded server-log prefix, and an existing directory is refused. The measurements are finite local observations and establish no provider throughput, soak result or universal memory bound (#adr(15)).],
      )
    ]
    #subsection(title: "Provider recording")[
      #points(
        [Sanitized named OpenAI, Gemini and TypeSafe cassettes replay offline and credential-free. The recorder is opt-in, spends provider tokens and is never part of a gate; it reads provider credentials only from its documented environment variables, and credential values never enter logs, source, telemetry or documentation.],
        [Publication and redaction results are inspected separately from successful generation. HTTP Gun removes its documented credential metadata, while prompt bodies, queries and unlisted headers can retain sensitive content and remain the recorder owner's responsibility. A cassette proves the named request and response at its recorded revision and model, not every offered model (#adr(13)).],
      )
      #behavior(title: "A replay never reaches a provider", area: "Playback", level: "boundary")[
        #given[A scripted or recorded exchange set serves a prepared request.]
        #when[A request is missing, corrupt, incompatible, mismatched or beyond the exhausted exchanges.]
        #then[The call fails without falling back to a network provider.]
        #then[A mismatch leaves the expected exchange unconsumed.]
      ]
    ]
    #subsection(title: "Testing and extension ports")[
      #answers(title: "Semantic test replies", responsibility: [Build protocol evidence without a live provider.], interface: [Opaque Reply and ScriptedCall builders describe text, tools, usage, refusal, output limit, content filter, status failures, interruption and in-band error; exchange lowers one Prepared(o) into HTTP Gun's Exchange. Classification reply builders target Prepared(a).], interactions: [Scripts, cassettes and local HTTP serve the same prepared and provider runtime path. Custom providers can supply raw event chunks.], invariants: [Lowering an already wire-specific reply preserves it; interrupted replies cannot synthesize success. Misuse such as a model-refusal fixture for Anthropic or Google fails explicitly.], failure: [Missing, mismatched or exhausted playback stays offline and leaves a mismatched expected exchange unconsumed. HTTP Gun owns capture and publication failures separately.])
      #points(
        [A #term("term-semantic-test-reply") lowers into the selected provider's own wire. Failure replies (rate limited, overloaded, status, interrupted, in-band stream error, content filtered, prompt blocked and invalid output) write the error status and body of a built-in provider, raw event chunks serve a custom wire, and a retry-after value attaches to an exchange. Replies also render as an HTTP response for a fake server, and a Failure value builds directly for code that consumes one.],
        [High-level final-answer substitution alone is not provider-reduction evidence. HTTP Gun owns scripts, binary cassettes, strict playback, recording and publication.],
      )
    ]
    #subsection(title: "Oracle evidence")[
      #points(
        [ReqLLM v1.24.0 is a pinned behavioral comparator, neither a dependency nor a parity commitment, and no upstream suite runs wholesale. #lnk("../ORACLE.md")[The oracle references] hold every pin, the selected cases, the exclusions and the run command. #term("term-oracle-evidence") pairs each selected upstream law with retained local assertions and states each difference or limit (#adr(5)).],
        [Exact request fixtures, malformed and fragmented SSE, offline cassettes and retained HTTP adoption receipts stay as preserved inputs. A newer model or extension needs its own named wire and ownership evidence.],
      )
    ]
  ])

  #section(title: "Extension boundaries", lead: "Supported scope is explicit; unbuilt capabilities keep their stated owner.", body: [
    #md-table(3, (
      [*Capability*], [*Current contract*], [*Owner of an extension*],
      [Provider-native options], [Account and version fields and common sampling, token and cache settings], [A complete custom adapter or a future typed provider option],
      [Content and reasoning], [Input images, semantic text, refusal and reasoning deltas, a text terminal], [A future ordered-block contract that keeps protocol meaning],
      [Tool modes and hosted tools], [Application tool batch admission; hosted activity observed conservatively], [A future policy with distinct provider-hosted outcomes],
      [Model metadata], [An explicit model string that the provider may reject], [An injected capability description with separately owned freshness],
      [Interaction lifecycle], [One HTTP and SSE generation, buffered classification or inline transcription; local close only], [A separate contract per new lifecycle],
      [Durability], [Message and replay codecs and pure classification receipts], [The application: versioning and recovery, with no wire checkpoint or one-time handle],
    ))
    #points([Extensions keep the shared admission, capacity, correlation and cleanup boundary where it applies. A new protocol with a different lifetime states its limits instead of inheriting SSE guarantees by name. Pending rulings in the generation context cover the unspecified provider-native and lifecycle scope (#adr(6)).])
  ])

  #section(title: "End-to-end walkthrough", lead: "A structured extraction can ask for tools while the application retains its policy and native type.", visual: sequence(
    title: "Caller-owned typed extraction and one tool round",
    participants: ((id: "caller", label: "Caller", shape: "participant"), (id: "wire", label: "LLM Wire", shape: "control"), (id: "http", label: "HTTP Gun", shape: "boundary"), (id: "tool", label: "Application tool", shape: "participant")),
    steps: (
      seq-msg("caller", "wire", "prepare invoice request + codec + tool"),
      seq-msg("wire", "caller", "Prepared(Invoice)", dashed: true),
      seq-msg("caller", "wire", "stream(client, prepared)"),
      seq-msg("wire", "http", "owned HTTP response scope"),
      seq-msg("wire", "caller", "Progress; Done NeedsTools(turn)", dashed: true),
      seq-msg("caller", "tool", "authorize, decode and execute"),
      seq-msg("tool", "caller", "result under call id", dashed: true),
      seq-msg("caller", "wire", "prepare appended turn + exact results"),
      seq-msg("caller", "wire", "run(client, new prepared)"),
      seq-msg("wire", "http", "new owned HTTP response scope"),
      seq-msg("wire", "caller", "Answer(Invoice) or typed Failure", dashed: true),
    ), caption: [The output type stays Invoice on the caller's request. History, approvals and execution remain visible application choices.],
  ), body: [
    #points(
      [The caller starts or supervises one HTTP Gun client, chooses provider configuration, declares get_weather from its native codec and creates Request(Invoice) with with_output. Preparation can reject the exact provider schema before HTTP.],
      [stream creates one owner and HTTP worker. Argument deltas remain progress; NeedsTools returns only after batch admission. The caller checks its registry/authorization/round budget, decodes arguments, performs the tool effect and preserves the complete assistant turn.],
      [Appending that turn and exact results retains the output codec and provider replay content. Re-preparing rechecks history and schemas. A final response is validated against the original Invoice contract before native decoding; unusable text remains a typed InvalidOutput failure with evidence.],
      [If a call fails, the caller considers advise together with send/progress and its remaining operation budget. A provider delay exceeding that budget ends the caller's attempt rather than causing an earlier retry. Closing a stream releases local resources without claiming provider rollback.],
      [For a durable non-generative decision, the caller instead fixes a classification wire/questions per operation version, obtains fresh live Config and runs one buffered request. It stores a receipt under its own enclosing-record bound; reopening decodes evidence through the pure fixed wire without credentials.],
    )
  ])
]
