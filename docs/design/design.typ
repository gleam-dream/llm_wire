#import ".render/designlib.typ": *

#let title = [LLM Wire]
#let accent = "blue"

#let body = [
  #section(title: "Foundation", lead: "One bounded provider interaction composes with a caller-owned application.", body: [
    #goal(title: "Return typed bounded provider interactions")[Direct callers and agent runtimes prepare, execute and stream one provider interaction without acquiring a tool loop or persistence runtime. OpenAI Responses, Anthropic Messages and Google GenerateContent remain baseline provider targets.]
    #goal(title: "Preserve caller values and provider meaning")[Structured generation returns the application's output type. Classification retains native choice values and evidence distributions. Provider replay requirements survive in response data.]
    #no-goal(title: "Own conversations or application effects")[The caller owns history, tool execution, authorization, approvals, retries, round budgets, durable recovery and duplicate-effect protection. LLM Wire owns no workflow checkpoint or background agent.]
    #no-goal(title: "Duplicate the generic HTTP runtime")[HTTP Gun owns connection and body lifetime, TLS, destination admission, pooling, byte transport and HTTP recording/playback.]
    #invariant(title: "Preparation opens no package-owned resource", enforcement: "mechanism")[Preparation performs local validation and encoding before transport. It starts no owner, timer or socket and emits no execution observation. Extension callbacks must respect their declared pure contract.]
    #invariant(title: "Incomplete arguments never become executable calls", enforcement: "mechanism")[Argument deltas are progress only. A normal tool-request terminal requires a complete admitted batch; output-limited calls remain explicitly partial.]
    #invariant(title: "One owner decides each stream terminal", enforcement: "mechanism")[All handles share terminal state. Terminal processing closes local transport; a later event cannot replace the outcome.]
    #invariant(title: "Unknown evidence remains unknown", enforcement: "mechanism")[Absent usage and optional classification confidence remain None. Local cancellation does not prove provider rollback or cancellation acknowledgement.]
    #principle(title: "Keep policies with their actual authority")[Adapters encode and interpret provider protocols. Shared runtimes retain admission, limits, correlation and resource cleanup. Applications decide whether another interaction is justified.]
    #principle(title: "Reject unsupported requests before effects")[A valid schema outside the selected provider profile fails explicitly. Unsupported requested features must not be silently discarded.]
  ])

  #pending-ledger(
    pending-entry(title: "Deliver bounded inline transcription", kind: "build", since: "2026-10-09", adr: [#adr(9)])[
      Implement the accepted inline transcription contract and qualify the public API with an independent consumer. Retain this entry until owner implementation acceptance.
    ],
    pending-entry(title: "Bound waiting in the retry teaching example", kind: "build", adr: [#adr(7)])[
      The public retry helper sleeps an uncapped ProviderDelay despite the contract requiring caller-owned waiting bounds. A finite attempt count does not bound that sleep. Correcting executable example behavior requires a separate change; a caller should refuse a requested wait exceeding its remaining budget rather than retry earlier than requested.
    ],
    pending-entry(title: "Resolve stream read authority", kind: "ruling", adr: [#adr(7)])[
      The public Stream documentation permits only the creating process to read. The owner accepts reads from other processes while allowing one pending read and retaining creator-owned lifetime. Neither side is newly approved by this capture; settle which read authority the public contract promises.
    ],
    pending-entry(title: "Specify richer provider-native generation", kind: "ruling", adr: [#adr(6)])[
      Retain sequential/parallel tool mode, tool choice, richer native options, optional injected model capabilities, provider-hosted tool outcomes, richer response blocks and typed extension payloads. Current native options cover credentials/account/version fields; adding a request field requires a complete custom adapter. Establish concrete advanced consumers before choosing narrow provider options or an admitted request extension.
    ],
    pending-entry(title: "Specify advanced interaction lifecycles", kind: "ruling", adr: [#adr(6)])[
      Beyond the bounded inline transcription specified below, retain richer audio/video, embeddings, realtime/WebSockets, provider batch/background work, interrupted-stream resumption and optional remote cancellation acknowledgement as extension or later-consumer scope. These need distinct protocol, state, ownership and compatibility contracts; they are not current generation guarantees.
    ],
    pending-entry(title: "Establish upstream allocation guarantees", kind: "verify", adr: [#adr(2)])[
      Package byte and queue bounds do not prove a strict pre-allocation bound for complete HTTP header blocks in Gun/Cowlib, native JSON allocation or arbitrary custom reducer state. HTTP parser hardening requires dependency evidence or a transport decision; no second parser or universal memory guarantee is introduced.
    ],
    pending-entry(title: "Broaden provider and runtime conformance evidence", kind: "verify", adr: [#adr(5)])[
      Selected local protocol, OTP, TLS/H2 and recorded-provider cases do not establish exhaustive provider parity, all current models, other runtime combinations or long-running soak. New classification wires need their own protocol and replay evidence. Registry publication and hosted CI remain operational work.
    ],
  )

  #section(title: "System at a glance", lead: "Generation, classification and transcription retain distinct models within one library.", visual: diagram(
    altitude: "L1", viewpoint: "context-ownership", title: "Authorities around one provider interaction",
    groups: ((id: "wire", label: "LLM Wire", kind: "bounded-context", tint: "blue"), (id: "external", label: "External authorities", kind: "domain", tint: "slate")),
    nodes: (
      (id: "app", label: "Application / Fabric", sub: "history, policy, effects", kind: "external-system", group: "external"),
      (id: "generation", label: "Generation", sub: "admission and semantic stream", kind: "component", group: "wire", tint: "blue"),
      (id: "classification", label: "Classification", sub: "questions and evidence", kind: "component", group: "wire", tint: "blue"),
      (id: "transcription", label: "Transcription", sub: "inline audio to text", kind: "component", group: "wire", tint: "blue"),
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
      [Gleam on Erlang/OTP is the execution platform. The JavaScript target is unsupported. The dependency boundaries and separation from agent state follow #adr(1) and #adr(2).],
    )
    #md-table(3, (
      [*Unit*], [*Owned model*], [*Child units*],
      [Generation admission], [Config, Request(o), Prepared(o), tool declaration], [Configuration, schema projection, conversation validation],
      [Provider interpretation], [Routing blocks, progress, terminal, replay data], [OpenAI, Anthropic, Google, public custom adapter],
      [Execution ownership], [Stream owner, queue, credit, timers, send evidence], [HTTP worker, SSE framer, delivery, terminal cleanup],
      [Classification], [Wire, live Config, Batch(a), candidates, Outcome(a)], [Questions, protocol adapter, transport, receipt codec],
      [Transcription], [Audio, Settings, Config, Prepared, nonempty text], [Admission, inline protocol, borrowed buffered exchange],
      [Verification], [Semantic replies, HTTP exchanges, cassettes], [Offline consumers, local protocol/ownership fixtures, opt-in recording],
    ))
  ])

  #section(title: "Generation admission", lead: "A reusable prepared value binds one encoded request to its output decoder.", body: [
    #subsection(title: "Values and refinements")[
      #entity(id: "generation-request", title: "Generation request", description: [The caller's explicit request and desired native output.], kind: "value-object", owner: "caller", lifecycle: "immutable", domain: "generation")[
        #attribute(name: "Input", type: "model string and ordered List(Message)", provenance: "authored")[Messages hold system/user text, user content parts, assistant turns, assistant content parts or tool results. Content parts are text, remote image URL or inline MIME/base64 image.]
        #attribute(name: "Options", type: "optional maximum tokens, temperature, top-p and cache reference; stop list", provenance: "authored")[Maximum tokens is positive; temperature is within 0 through 2; top-p within 0 through 1. Model/output name is trimmed and nonempty. Cache references are nonempty and provider-specific.]
        #attribute(name: "Output", type: "String or Blueprint Codec(o)", provenance: "authored")[Plain text returns String. with_output changes only the output type and retains the remaining request settings.]
        #relates(cardinality: "1 : 0..n")[A request declares zero or more tools and contains an ordered caller-owned conversation.]
      ]
      #entity(id: "prepared-generation", title: "Prepared generation", description: [The opaque result of admitting one configured request.], kind: "value-object", owner: "generation admission", lifecycle: "immutable", domain: "generation")[
        #attribute(name: "Admitted material", type: "adapter, normalized request, tools, body and output contract", provenance: "derived")[The encoded body and admitted schemas are fixed. Headers are captured behind an inspection-safe closure.]
        #attribute(name: "Execution settings", type: "limits, timeouts, tool-check policy and Codec(o) decoder", provenance: "derived")[Reusing this value creates another execution and a new call identifier. It grants no single-use or duplicate-effect protection.]
        #relates(cardinality: "1 : 0..n")[One prepared generation can create multiple independent executions.]
      ]
      #points([Public constructor values are opaque where arbitrary construction could bypass admission. Returned records are read by label; extensible sums use a fallback arm. Generation's Config, Request(o), Prepared(o), Stream(o), tool declaration and Adapter keep private machinery out of caller type parameters. #adr(3) records this facade.])
    ]
    #subsection(title: "Configuration and preparation")[
      #answers(title: "Generation preparation", responsibility: [Validate and encode one request without networking.], interface: [prepare(Config, Request(o)) returns Prepared(o) or PrepareError; request_json reads the encoded body without credentials.], interactions: [Uses adapter validation, endpoint admission, tools, schema projection and the caller's output codec.], invariants: [Selected provider, admitted contracts and native decoder remain together. Invalid local values never reach HTTP.], failure: [InvalidSetting, InvalidRequest, UnsupportedSchema, ToolResultMismatch or RequestTooLarge name the refused boundary. Diagnostic strings are not classification keys.])
      #points(
        [Built-in settings hold their keys behind reveal closures. OpenAI adds organization/project; Anthropic adds API version; Google adds API version. Common settings own limits, three time bounds and tool-call checking. All bounds must be positive unless an explicit timeout Infinity is selected.],
        [Preparation validates timeouts, adapter settings, positive limits, trimmed model, historical turns, unique tool names and projected tool/output schemas. It then validates endpoint and common/provider options, calls the encoder, reveals and validates provider headers, validates the joined path and bounds the encoded body.],
        [Generation endpoint admission requires HTTP(S), a host, an admitted port and a path without userinfo, query, fragment or controls. Encoded paths cannot inject a new authority or controls. Header names/values and reserved common headers are checked; credentials remain inspection-safe but the application must govern logging of prompt bodies.],
        [OpenAI refuses stop sequences; Anthropic and Google admit finite lists, with Google's maximum five. OpenAI admits remote image URLs; Anthropic and Google require inline image content. Cache references are OpenAI prompt_cache_key or Google cachedContent; other providers reject them.],
        [Custom projection/encoding/header callbacks run synchronously during preparation. Their declared purity excludes networking and uncontrolled effects; the type system cannot enforce that promise. Generation header values are captured during prepare, so changing credentials requires preparing again.],
      )
      #behavior(title: "Invalid local input fails before networking", area: "Preparation", level: "interface")[
        #given[A generation request has an invalid configuration, option, schema or tool-result association.]
        #when[The caller prepares the request.]
        #then[Preparation returns the relevant typed preparation error.]
        #then[No generation execution starts.]
      ]
    ]
    #subsection(title: "Schema-bearing boundaries")[
      #md-table(3, (
        [*Schema location*], [*Admitted shapes*], [*Refused shapes*],
        [Built-in tool parameters], [string/enum, integer/range, number, bool, any; recursive list, nullable, object], [pair, union, number range, unknown kind],
        [OpenAI/Anthropic output], [record root; required closed nested objects, lists, nullable, enums, integers/ranges and nested tagged union], [non-record root, optional property, pair, number range, any, unknown kind],
        [Google output], [record root; also optional fields, pair, number range and any below root], [non-record root and unknown kind],
        [Custom adapter], [its explicit projection callbacks; Blueprint's canonical schema by default], [whatever its projection returns as unsupported],
      ))
      #points(
        [Nested Blueprint unions become anyOf of closed variant objects; each tag is a one-element string enum. The original codec still decodes the response, so this projection cannot bless a different native value. Google's field is generationConfig.responseJsonSchema; tool declarations use parametersJsonSchema. #adr(4) records protocol-specific evidence.],
        [tool.new is for authored declarations and panics with the tool name when its name/schema is invalid. Runtime from_contract/from_json_schema returns ToolError. Tool names match ASCII letters, digits, underscore or hyphen, with length 1 through 64. Schema-only MCP input needs no Relay type or runtime dependency.],
        [Schema-only admission inherits Blueprint's supported profile and loader failures. It is not general JSON Schema support; unsupported external MCP schemas remain explicitly refused. Native tool arguments and final output are parsed within byte/depth bounds, validated against the original contract, then decoded. Schema-invalid values never enter codec mapping callbacks.],
      )
      #behavior(title: "Unusable structured output retains its evidence", area: "Output validation", level: "interface")[
        #given[An admitted structured request receives final text that is malformed JSON, schema-invalid or rejected by its codec.]
        #when[The completed output is decoded for the caller.]
        #then[The result is InvalidOutput with the original text and typed ValueFailure.]
        #then[Send evidence is Completed and reported usage remains available.]
      ]
    ]
  ])

  #section(title: "Caller-owned conversation", lead: "A tool terminal returns response data for the caller's next ordinary request.", body: [
    #entity(id: "assistant-turn", title: "Assistant turn", description: [One response value preserved by the caller.], kind: "value-object", owner: "message model", lifecycle: "immutable", domain: "conversation")[
      #attribute(name: "Response", type: "provider option, text, calls, response-id option, provider-data option", provenance: "observed")[Application-written turns may omit provider. A provider-produced turn names its provider and retains required replay data.]
      #relates(cardinality: "1 : 0..n")[One assistant turn carries an ordered batch of tool calls; each call has one round-local application correlation id.]
    ]
    #entity(id: "tool-call", title: "Tool call", description: [A provider's request for an application tool result.], kind: "value-object", owner: "provider response", lifecycle: "immutable", domain: "conversation")[
      #attribute(name: "Identity", type: "id and name strings", provenance: "observed")[The call id differs from provider decoder routing keys. Ids may repeat in different assistant turns; names are constrained by the common tool-name grammar.]
      #attribute(name: "Payload", type: "arguments JSON and optional provider id/state", provenance: "observed")[Provider id/state is replay metadata. Argument text remains exact response evidence until native decoding.]
    ]
    #answers(title: "Conversation validation", responsibility: [Validate each historical assistant batch and following results.], interface: [append retains a request's options and output codec; message codecs store response data; prepare validates the resulting transcript.], interactions: [The caller executes tools and appends Assistant(turn) plus one ToolResult per call. The provider encoder interprets message-local replay data.], invariants: [Every call has exactly one immediately following result; result order is normalized to call order. Historical calls need not belong to the current catalog.], failure: [Missing, duplicate, unknown or unassociated result ids fail before transport; turns from another provider and inconsistent replay data are refused.])
    #points(
      [A tool-request terminal must contain a nonempty batch with unique ids, finite metadata/arguments and complete provider blocks. Unknown tools and invalid arguments fail by default; ReportInvalidToolCalls retains all calls with #term("term-tool-call-issue") values. Duplicate identities and capacity violations always fail.],
      [A returned call does not grant application registry membership, authorization or execution permission. Reporting a bad call makes it answerable as a tool error message; it does not make it executable. The caller owns round limits, approvals and retry policy.],
      [Google signed parts are retained in each turn's #term("term-replay-data"). Encoding checks that raw parts agree with normalized text/calls and preserves signed content/order; unsigned parts use canonical argument repair. Custom interpretation belongs to the configured adapter.],
      [message.to_json/decoder uses llm_wire.message.v1; turn_to_json/turn_decoder uses llm_wire.turn.v1. A missing format tag is read as version 1; a different tag is rejected. turn_replay_to_json stores provider/id/data alone; its decoder takes separately stored text/calls and tolerates the former issues field in Fabric records.],
      [Message decoders restore data shape rather than admission or trust. The storage reader bounds its enclosing record; preparing a restored conversation revalidates it. Neither saved turns nor prepared values provide one-time consumption. #adr(1) records the replacement of wire-owned continuation.],
    )
    #behavior(title: "A follow-up requires exact local result coverage", area: "Conversation", level: "boundary")[
      #given[An assistant message contains tool calls and the caller supplies a follow-up request.]
      #when[The follow-up is prepared.]
      #then[Missing, duplicate or unknown result ids are refused before transport.]
      #then[An admitted request places results in that assistant turn's call order.]
    ]
    #behavior(title: "Reporting policy retains invalid calls", area: "Tool admission", level: "interface")[
      #given[A complete bounded tool batch contains an undeclared tool or arguments rejected by its declaration, and reporting is selected.]
        #when[The owner admits the completed tool-request terminal.]
      #then[NeedsTools contains every call and the corresponding typed issues.]
    ]
  ])

  #section(title: "Provider interpretation", lead: "Each adapter translates wire events without acquiring execution policy.", body: [
    #subsection(title: "Shared protocol contract")[
      #answers(title: "Provider adapter", responsibility: [Encode admitted requests and reduce provider events into semantic progress and terminals.], interface: [provider.new accepts identity, endpoint, encoder and reducer factory; schema projection/header callbacks are separate; reducer state remains hidden.], interactions: [Shared admission supplies projected tools/output; the owner supplies finite SSE events and validates returned progress and terminals.], invariants: [Callbacks cannot bypass shared tool-batch, metadata, text and queue admission. Unknown events do not become application tool calls.], failure: [Encoder/projection errors refuse preparation. Reducer errors terminate execution with local cleanup; custom state size and synchronous callback termination remain adapter-author obligations.])
      #points(
        [Progress alternatives are TextDelta, RefusalDelta, ReasoningDelta, ToolArgumentsDelta, UsageUpdate and ProviderExtension. Public extension values retain a bounded event name, not an arbitrary raw payload. A custom adapter returns text, tool_calls, output_limited, refused or failed terminal values.],
        [Built-in reducers track provider routing keys, ordered blocks, completion flags, usage and observed evidence. Deltas after closure, contradictory routing, duplicate starts/ids, malformed arguments or incomplete normal terminal calls fail. Multiple tool calls remain in declaration order despite interleaved completion.],
        [Outcome(o) separates Answer(output, text, usage), NeedsTools(turn, issues, usage), OutputLimited(partial_text, partial_calls, usage), and Refused(reason, usage). OutputLimited data is incomplete evidence and must not enter normal tool dispatch. ContentFiltered is a failure, distinct from a model's own refusal.],
        [Usage is optional. Anthropic cumulative output updates replace the prior total rather than being summed; Google/OpenAI report their own final or updated counts. No provider usage parity is claimed for detailed cache/reasoning billing.],
      )
      #state-type(id: "block-state", title: "Provider block state", variants: ("absent", "open", "complete", "invalid"))
      #entity(id: "provider-block", title: "Provider block", description: [A routed text or argument buffer in one reducer.], kind: "entity", owner: "provider reducer", lifecycle: "stateful", domain: "generation")[
        #attribute(id: "state", name: "State", type: "Provider block state", provenance: "derived", state-type: "block-state", state-machine: "block-lifecycle")[A block is absent until its declared start; closed content cannot accept further deltas.]
        #attribute(name: "Routing and bytes", type: "provider key, application id where relevant, bounded buffer", provenance: "observed")[Routing keys remain internal. Completed argument text is parsed before a normal tool terminal.]
      ]
      #state-machine(id: "block-lifecycle", subject: "provider-block", state-field: "state", state-type: "block-state", title: "A block accepts fragments before completion", initial: "absent", accepting: ("complete", "invalid"), states: ("absent", "open", "complete", "invalid"), transitions: (("absent", "open", "start"), ("open", "open", "delta"), ("open", "complete", "validated stop"), ("open", "invalid", "malformed or incomplete"), ("complete", "invalid", "late or contradictory delta")), caption: [The owner converts invalid grammar into one stream failure. This common model does not replace each protocol's routing rules.])
    ]
    #subsection(title: "Built-in protocol families")[
      #md-table(3, (
        [*Provider*], [*Routing and encoding*], [*Terminal and exceptional meaning*],
        [OpenAI Responses], [output_index and item id route text/reasoning/function arguments; application correlation uses call_id; input/output contracts use Responses forms], [completed/incomplete/failed and in-band error are distinct; max_output_tokens is output-limited; content_filter is ContentFiltered; refusal content is Refused],
        [Anthropic Messages], [content block index routes text/tool_use; tool_use.id is application id; result is user tool_result; system text is separate], [message_stop requires completed blocks; max_tokens is output-limited; refusal stop is ContentFiltered; server_tool_use is tracked separately from application calls],
        [Google GenerateContent], [model path streamGenerateContent with SSE; functionCall ids are retained or locally synthesized; model/user parts carry signed replay content], [STOP completes; MAX_TOKENS is partial; promptFeedback and safety finish reasons become ContentFiltered; provider errors and unknown stop reasons fail explicitly],
      ))
      #points(
        [OpenAI unknown named events produce bounded ProviderExtension. Anthropic ping produces no progress and unknown named events produce extensions. Google reduction reads its JSON payload rather than relying on named SSE events. Usage/extension/ping activity cannot end the first-progress wait.],
        [Provider-hosted actions can already have effects. Anthropic server-tool observation and ambiguous tool activity strengthen internal uncertainty; these do not authorize application dispatch. A public structured provider-hosted outcome remains an explicit pending contract.],
        [Generation wire JSON uses standard Gleam JSON; duplicate-member rejection is not universally promised for provider envelopes. Tool/output schema values use Blueprint so exact schema numbers do not pass through a Float bridge. #adr(4) and #adr(5) distinguish profile support from measured provider evidence.],
      )
    ]
    #behavior(title: "A protocol failure ends the owned stream", area: "Provider reduction", level: "interface")[
      #given[A provider sends malformed or contradictory events before the stream ends.]
      #when[The interaction interprets those events.]
      #then[The stream ends with a typed protocol failure and releases local transport.]
      #then[It returns no normal completed tool batch from the partial arguments.]
    ]
    #behavior(title: "Content filtering preserves provider meaning", area: "Terminal outcomes", level: "interface")[
      #given[A built-in provider reports an admitted prompt or output content-filter stop.]
        #when[The reducer handles that filtering terminal.]
      #then[The failure contains ContentFiltered with stage and the provider's reason, and Completed send evidence.]
      #then[Retry advice says WillNotHelpUnchanged.]
    ]
  ])

  #section(title: "Execution ownership", lead: "One generation owner serializes state while one linked worker consumes HTTP bytes.", visual: diagram(
    altitude: "L3", viewpoint: "runtime", title: "One stream execution and its resource authorities",
    nodes: (
      (id: "creator", label: "Creating caller", sub: "monitored lifetime", kind: "external-system"),
      (id: "owner", label: "Semantic owner", sub: "state, queues, timers", kind: "component", tint: "blue"),
      (id: "worker", label: "Linked HTTP worker", sub: "token and body scope", kind: "component", tint: "blue"),
      (id: "body", label: "HTTP Gun body", sub: "one opener/consumer", kind: "external-system"),
      (id: "framer", label: "SSE + reducer", sub: "finite incremental state", kind: "component", tint: "blue"),
    ),
    edges: (
      (from: "creator", to: "owner", relation: "call", label: "read / close"),
      (from: "owner", to: "worker", relation: "dependency", label: "lifetime + one credit"),
      (from: "worker", to: "body", relation: "call", label: "open / next / close scope"),
      (from: "worker", to: "owner", relation: "dataflow", label: "one chunk then wait"),
      (from: "owner", to: "framer", relation: "call", label: "admit / interpret"),
    ), caption: [The stream handle names the owner. The worker alone opens and reads the HTTP body; cancellation covers its whole scope.],
  ), body: [
    #subsection(title: "State and delivery")[
      #state-type(id: "stream-state", title: "Stream state", variants: ("unstarted", "open", "terminal-pending", "ended"))
      #entity(id: "stream-execution", title: "Stream execution", description: [One authoritative process for one started generation.], kind: "aggregate", owner: "stream owner", lifecycle: "stateful", domain: "execution")[
        #attribute(id: "state", name: "State", type: "Stream state", provenance: "derived", state-type: "stream-state", state-machine: "stream-lifecycle")[The terminal slot latches the first outcome. Accepted queued progress precedes that terminal unless explicit local close ends delivery.]
        #attribute(name: "Delivery", type: "bounded FIFO, one optional pending read and read identity", provenance: "derived")[Count/byte counters track the FIFO. Read timeout arbitration decides whether cancellation or delivery won; waiting readers are monitored.]
        #attribute(name: "Resource and evidence", type: "transport port, credit, timer handles, monotone evidence, last usage", provenance: "derived")[Creator death cancels the call. The transport-closed flag guards normal-path local cleanup.]
        #relates(cardinality: "1 : 1")[Each started owner holds one linked transport worker and one private reducer.]
      ]
      #state-machine(id: "stream-lifecycle", subject: "stream-execution", state-field: "state", state-type: "stream-state", title: "A terminal closes transport before delivery ends", initial: "unstarted", accepting: ("ended",), states: ("unstarted", "open", "terminal-pending", "ended"), transitions: (("unstarted", "open", "start succeeds"), ("unstarted", "ended", "startup failure"), ("open", "open", "accepted progress / timed-out read"), ("open", "terminal-pending", "provider terminal / failure / timer"), ("terminal-pending", "ended", "deliver terminal"), ("open", "ended", "close / creator death"), ("terminal-pending", "ended", "close / creator death")), caption: [Terminal pending retains already queued progress but no live HTTP scope. There is no transition back to open; a prepared value starts a new owner.])
      #answers(title: "Read and close protocol", responsibility: [Serialize delivery and terminate locally when requested.], interface: [stream returns before HTTP headers; next waits, next_within adds a local wait, collect discards progress; close returns Closed or AlreadyEnded.], interactions: [Reads share one owner and FIFO. Close latches cancellation; pending-reader death clears only its read. Creating-caller death releases the whole execution.], invariants: [One pending read; one terminal; copied handles share closure. A read timeout leaves the stream readable.], failure: [ReadError is StreamEnded, ConcurrentRead, OwnerGone or TimedOut. Owner startup fails as Stopped/NotSent; loss while collecting returns conservative Stopped/MaybeSent evidence.])
      #points(
        [The current owner accepts cross-process reads and rejects another pending reader; its public comment declares creator-only reads. Lifetime ownership and read authority are distinct. The pending ruling preserves this conflict.],
        [Close and owner exit settle against pending delivery. A terminal already delivered wins; repeated close is idempotent even when the owner has exited. A queued provider terminal cannot be replaced by late HTTP events. Early provider completion closes transport without draining to HTTP EOF.],
        [Normal cleanup cancels timers, closes the transport once and clears pending monitors. Abnormal owner death terminates its linked worker; HTTP Gun observes opener death. Command cardinality does not prove exactly-once cleanup effects under arbitrary process loss.],
      )
      #behavior(title: "A read wait expires without cancelling generation", area: "Read delivery", level: "interface")[
        #given[A stream remains active without an event during the caller's shorter read wait.]
        #when[The caller reads with next_within.]
        #then[It receives TimedOut unless delivery wins the same race.]
        #then[The stream remains available for a later read.]
      ]
      #behavior(title: "Close is shared and idempotent", area: "Lifetime", level: "interface")[
        #given[Multiple handles name the same stream.]
        #when[A caller closes one handle.]
        #then[The active local interaction is cancelled or an existing end is reported.]
        #then[Other handles cannot keep independent live executions.]
      ]
      #behavior(title: "Creator death releases the interaction", area: "Lifetime", level: "boundary")[
        #given[The process that started a stream exits while it is opening or reading.]
        #when[Its exit is observed.]
        #then[The interaction cancels and releases its local connection resource.]
      ]
    ]
    #subsection(title: "Effect timing and deadlines")[
      #md-table(3, (
        [*Boundary*], [*Effect and time owner*], [*Failure or limit*],
        [prepare], [local projection/encoding and generation header reveal; no execution clock], [typed pure admission error; trusted callbacks must terminate],
        [stream], [fresh call id; absolute whole-call deadline before reducer/owner setup], [Stopped if owner setup fails; remaining deadline reaches HTTP and owner],
        [owner setup], [linked worker plus first-progress timer and creator monitor], [startup wait is bounded by actor/worker setup; synchronous adapter factory is not preempted],
        [HTTP opening], [worker token scope; HTTP Gun admission/connect/headers consume whole-call budget], [typed HTTP failure or WholeCall deadline],
        [SSE interpretation], [first semantic progress cancels FirstToken and starts IdleGap; every framed event then resets idle], [comments/bytes alone do not reset semantic idle],
        [terminal], [local cancellation/close immediately; queued delivery may follow], [no remote rollback or cancellation guarantee],
        [structured decoding], [caller-side output validation after semantic terminal and HTTP cleanup], [InvalidOutput; synchronous codec callback has no independent preemption],
      ))
      #points(
        [WholeCall defaults to 600 seconds. FirstToken defaults to 180 seconds; it begins during owner setup, after reducer factory and transport initializer work, and ends at the first accepted semantic progress. IdleGap defaults to 60 seconds after that point. Infinity lifts each independently. Preparation and caller retry waiting are outside these timers.],
        [Generation applies the same absolute deadline to HTTP Gun and uses its remaining duration in the owner. It replaces the HTTP request timeout and lifts HTTP idle; connect and pool admission bounds still apply. Synchronous custom factory/reducer/output callbacks are trusted code and may delay observing elapsed time.],
        [For HTTPS, the supplied client's destination policy remains. For admitted plaintext, the implementation configures default destination policy with loopback/private admission and PlaintextToLoopbackOnly through with_destination. HTTP Gun combines view constraints; this setup is not a claim that a caller's refusal can always be overridden or merely narrowed. Resolved non-loopback plaintext remains refused.],
        [Status 200 requires text/event-stream and absent/identity encoding. Other status bodies are bounded by ErrorBodyBytes and retained as Status with Retry-After; body/stream errors preserve independent observed-byte evidence. HTTP Gun does not add retries, redirects or decompression to this path.],
      )
      #behavior(title: "A generation timer ends local execution", area: "Deadlines", level: "interface")[
        #given[An executing generation exceeds an applicable whole-call, first-progress or idle-gap timer.]
        #when[The deadline is observed.]
        #then[The interaction ends with DeadlineExceeded naming that timer and local cleanup.]
        #then[It does not restart the request.]
      ]
    ]
    #subsection(title: "Framing and capacity")[
      #answers(title: "Incremental SSE framer", responsibility: [Reconstruct finite events from arbitrary binary chunks.], interface: [feed consumes bytes and returns events plus remaining framing state; finish handles EOF.], interactions: [The owner checks response bytes, frames events and steps its provider reducer; the worker waits for further credit.], invariants: [LF/CRLF, split CRLF and split UTF-8 retain their meaning; line/event growth and per-chunk event counts are finite.], failure: [Invalid UTF-8 or malformed framing fails; incomplete EOF is handled explicitly rather than manufacturing a provider terminal. LimitExceeded names the violated setting.])
      #points(
        [The framer retains an incomplete binary line, partial event fields, data fragments and scan position. Comments are ignored; multiple data lines join with newlines; event/id/retry fields retain their typed SSE meanings. A blank line dispatches an event. A long incomplete line resumes scanning rather than rescanning all prior bytes.],
        [One worker sends one chunk then waits for one credit. The owner requests more only below count and byte watermarks with no outstanding credit. Events already present in a chunk may overflow and fail; pull shape does not promise that one incoming chunk cannot contain many events. The terminal has a separate slot so a full progress queue cannot erase it.],
        [The owner rechecks custom-provider progress text/block/extension and terminal text/arguments/metadata. Built-ins additionally bound their own block buffers. Common checks cannot prove an arbitrary custom reducer's captured state is finite. HTTP Gun's upstream body queue is a separate bound.],
      )
      #md-table(3, (
        [*Limit*], [*Default*], [*Boundary*],
        [RequestBytes], [1 MiB], [encoded generation body before execution],
        [ChunkBytes], [64 KiB], [incoming transport chunk],
        [LineBytes / EventBytes], [1 MiB / 1 MiB], [incremental SSE line/event],
        [ResponseBodyBytes / ErrorBodyBytes], [8 MiB / 64 KiB], [stream bytes / retained error body],
        [QueueCount / QueueBytes], [500 / 2 MiB], [undelivered progress and framer event capacity],
        [ActiveBlocks], [64], [active reducer blocks and returned call count],
        [TextBytesPerBlock / TotalTextBytes], [1 MiB / 4 MiB], [semantic text and terminal validation],
        [ArgumentBytesPerCall / TotalArgumentBytes], [1 MiB / 4 MiB], [tool argument buffers and admitted terminal],
        [ProviderMetadataBytes], [1 MiB], [id/name/signature/raw replay aggregate per turn],
        [ExtensionBytes], [16 KiB], [uninterpreted event name],
      ))
      #behavior(title: "A capacity violation ends the interaction", area: "Capacity", level: "interface")[
        #given[A generation exceeds a configured byte or count bound.]
        #when[The bounded input or output is admitted.]
        #then[The call fails with LimitExceeded naming the setting and measurement, or RequestTooLarge during preparation.]
        #then[No silent truncation makes the value appear complete.]
      ]
    ]
  ])

  #section(title: "Failure and retry evidence", lead: "A prospect for another attempt is independent of proof about provider work.", body: [
    #md-table(3, (
      [*Failure field*], [*Meaning*], [*Caller obligation*],
      [error], [Http, Status, Provider, Protocol, LimitExceeded, DeadlineExceeded, Cancelled, InvalidOutput, Stopped, ContentFiltered], [branch on variants/closed Kind; diagnostics are for people],
      [sent], [NotSent, MaybeSent or Completed], [do not infer rollback or free repeated work],
      [partial_output], [semantic progress accepted before failure], [accepted progress may already be externally visible],
      [provider / usage], [origin and last reported token counts], [retain unknown usage rather than zero],
    ))
    #points(
      [Internal evidence retains NoRequestSent, RequestMayHaveReachedProvider, ResponseCompleted or EffectUnknown plus byte/progress flags. Independent observations are merged monotonically; stronger uncertainty cannot be erased by a later HTTP error. Public #term("term-send-evidence") deliberately collapses uncertain effect to MaybeSent.],
      [advise reads Failure alone. HTTP unavailable/network/timeout failures may help; invalid/refused/too-large/cancelled/misuse/playback failures will not help unchanged. DeadlineExceeded may help; capacity, local cancellation and filtering will not; protocol, invalid output, stopped and unknown provider codes remain Unknown.],
      [Statuses 408, 429, 500, 502, 503 and 504 may help; Anthropic 529 may help. Common client/account/request rejection statuses will not help unchanged. Provider error-code mappings are exact, per provider; diagnostic prose is never parsed.],
      [RetryDelay is #term("term-provider-delay") when Retry-After is readable, otherwise Backoff. Delay seconds and HTTP dates are supported; a past date yields zero. Prospect says neither replay-safe nor successful: the caller weighs sent/progress, hosted effects, remaining deadline, budgets and its chosen retry owner. #adr(3) records this distinction.],
      [LLM Wire performs no automatic retry. Scheduling a provider delay as a snooze may preserve a queue attempt, while ordinary queue retry consumes one under Grind's own contract. The application translates that distinction without a shared retry runtime.],
    )
    #behavior(title: "Retry advice never schedules another call", area: "Retry advice", level: "interface")[
      #given[A caller has a failed interaction.]
      #when[It requests retry advice.]
      #then[It receives a prospect and provider delay or caller-backoff choice.]
      #then[No wait, new request or tool effect occurs.]
    ]
  ])

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
      #behavior(title: "Receipt limits are checked before credentials", area: "Classification preparation", level: "interface")[
        #given[A live byte allowance is nonpositive or exceeds the wire's fixed receipt allowance.]
        #when[The caller prepares classification.]
        #then[Preparation returns InvalidSetting for that limit.]
        #then[No credential closure is invoked and no provider request occurs.]
      ]
    ]
    #subsection(title: "Durable receipt reconstruction")[
      #answers(title: "Classification receipt codec", responsibility: [Reconstruct a native answer solely from saved protocol evidence.], interface: [receipt_codec(wire, questions) is a Blueprint Codec(Outcome(a)) with no schema; supports current and original TypeSafe bridge tags.], interactions: [The embedding store versions its operation/wire and separately bounds the enclosing record, including escaping and state.], invariants: [The reconstructed request equals saved request canonically and response candidates satisfy the same authored questions. Encoding rejects forged native outcomes.], failure: [Wrong format, oversized evidence, changed questions or inconsistent response/native answer fails codec encoding/decoding; no credentials or provider call is used.])
      #points(
        [The current array tag is llm.classification.receipt.v1 with requested model, state, request JSON and response JSON. Legacy fabric.typesafe.receipt.v1 contains request/response only; model and state are recovered from the bounded legacy request. Both follow the same reconstruction.],
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

  #section(title: "Observability and verification", lead: "Tests exercise real reducer paths while observations report bounded lifecycle facts.", body: [
    #subsection(title: "Observation contract")[
      #answers(title: "LLM observation", responsibility: [Report execution facts without transferring authority to observers.], interface: [telemetry.event() is Sinal's llm_wire/observation event; Metadata holds call, correlation, stage, provider and outcome.], interactions: [The execution copies correlation from the supplied HTTP Gun view so HTTP/LLM events join once.], invariants: [A retry gets a fresh call id. Content, credentials, arguments and status bodies are absent from telemetry.], failure: [Observation does not replace terminal state or authorize retry. Synchronous observer runtime behavior belongs to Sinal and the embedding application.])
      #points(
        [Stages are Started, RequestSent, FirstProgress, Terminal, Cancelled, Deadline and Cleanup. RequestSent marks arrival of the response head with http_response_started, not an exact network submission timestamp. Classification's buffered path emits that stage after send returns.],
        [Generation emits semantic owner facts; classification and transcription emit Started, buffered response, Terminal and Cleanup. prepare emits nothing. End-to-end latency measurement surrounds execution rather than subtracting a fabricated send timestamp.],
      )
    ]
    #subsection(title: "Testing and extension ports")[
      #answers(title: "Semantic test replies", responsibility: [Build protocol evidence without a live provider.], interface: [Opaque Reply/ScriptedCall builders describe text/tools/usage/refusal/output limit/filter/status/interruption/error; exchange lowers one Prepared(o) into HTTP Gun's Exchange. Classification reply builders target Prepared(a).], interactions: [Scripts, cassettes and local HTTP serve the same prepared/provider runtime path. Custom providers can supply raw event chunks.], invariants: [Lowering an already wire-specific reply preserves it; interrupted replies cannot synthesize success. Misuse such as model-refusal fixtures for Anthropic/Google fails explicitly.], failure: [Missing/mismatched/exhausted playback stays offline and leaves a mismatched expected exchange unconsumed. HTTP Gun owns capture and publication failures separately.])
      #points(
        [The separate consumer demonstrates common calls, caller-native Weather, multiple tool rounds, streaming, retry advice, full custom provider construction, shared client supervision, early close, concurrency and cassette playback using public imports only. Its classification consumer proves an independent array envelope, native labels, heterogeneous questions, custom auth/limits, absent measurements and receipts.],
        [Unit/reducer suites cover strict schema/output/tool admission, routing, fragmentation, usage, malformed events and semantic bounds. Owner/HTTP suites cover copied handles, conflicts, timed-read races, caller/owner death, pre-header close, absolute deadlines, slow readers and terminal-before-EOF. Local H1/TLS/H2 checks cover trust, reuse and sibling isolation under finite workloads.],
        [The fast/full gates and opt-in recording instructions live in docs/testing.md. Production has no handwritten Erlang FFI; test bridges provide TCP, clocks and resource measurements. Classification's local Python server has its own malformed-request/bound tests. These are verification mechanisms rather than proof of universal conformance.],
        [Raw evidence receipts, request fixtures and live cassettes remain. test/oracle/README.md records selected exact ReqLLM cases and pinned provenance; it does not claim the upstream suite was executed. The anthropic_gleam reuse experiment remains development-only because its event retention/filtering fails the bounded strict reducer contract. #adr(5) owns that decision.],
      )
    ]
  ])

  #section(title: "Retained extension scope", lead: "Current portable support is explicit; deferred capabilities keep their intended ownership.", body: [
    #md-table(3, (
      [*Capability*], [*Current contract*], [*Retained direction*],
      [Provider-native options], [account/version fields and common sampling/token/cache settings; complete custom adapter port], [typed reasoning/effort/tool choice and incompatible-option admission after concrete consumer evidence],
      [Content and reasoning], [input images; semantic text/refusal/reasoning deltas; text terminal], [richer ordered blocks, reasoning metadata and audio/video without erasing protocol meaning],
      [Tool modes and hosted tools], [application tool batch admission; hosted activity conservatively observed internally], [sequential/parallel policy and distinct already-executed provider-hosted outcomes],
      [Model metadata], [explicit model string; provider may reject it remotely], [optional injected known/unknown capability descriptions and separately owned catalog freshness],
      [Interaction lifecycle], [one HTTP/SSE generation, buffered classification or inline transcription; local close only], [realtime, batch/background, embeddings, resumption and acknowledged remote cancellation need separate contracts],
      [Durability], [message/replay data codecs and pure classification receipts], [application-owned versioning/recovery; no wire checkpoint, hidden history or one-time handle claim],
    ))
    #points([Extensions retain the shared admission, capacity, correlation and cleanup boundary where that boundary applies. A new protocol with a different lifetime must state its limits instead of inheriting SSE guarantees by name. The pending rulings and #adr(6) preserve the full source scope without claiming unbuilt support.])
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
