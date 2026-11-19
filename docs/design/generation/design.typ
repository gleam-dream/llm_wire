#import "../.render/designlib.typ": *
#import "CONTEXT.typ": accent

#let title = [Generation]

#let body = [
  #section(title: "Foundation", lead: "One generation is one prepared request, one owned semantic stream and one typed outcome.", body: [
    #goal(title: "Return typed bounded generations")[Direct callers and agent runtimes prepare, execute and stream one provider interaction without acquiring a tool loop or persistence runtime. OpenAI Responses, Anthropic Messages and Google GenerateContent are the baseline provider targets; a public custom adapter uses the same execution API.]
    #goal(title: "Preserve caller values and provider meaning")[Structured generation returns the application's output type. Provider replay requirements survive in response data. Reusable generation settings configure sampling, limits and cache references without owning conversation or output types.]
    #no-goal(title: "Own conversations or application effects")[The caller owns history, tool execution, authorization, approvals, retries, round budgets, durable recovery and duplicate-effect protection. Generation owns no workflow checkpoint or background agent.]
    #invariant(title: "Preparation opens no package-owned resource", enforcement: "mechanism")[Preparation performs local validation and encoding before transport. It starts no owner, timer or socket and emits no execution observation. Extension callbacks must respect their declared pure contract.]
    #invariant(title: "Incomplete arguments never become executable calls", enforcement: "mechanism")[Argument deltas are progress only. A normal tool-request terminal requires a complete admitted batch; output-limited calls remain explicitly partial.]
    #invariant(title: "One owner decides each stream terminal", enforcement: "mechanism")[All handles share terminal state. A later event cannot replace the outcome. An outcome decided at or after the provider terminal is delivered only after the worker has left its HTTP scope, with the body read to its end or cut at the trailing-read bound, or once the owner's backstop beyond that bound passes. Any other outcome, and close or creator death at any point, requests the close of local transport before delivery and does not wait for it.]
    #principle(title: "Keep policies with their actual authority")[Adapters encode and interpret provider protocols. Shared runtimes keep admission, limits, correlation and resource cleanup. Applications decide whether another interaction is justified.]
    #principle(title: "Reject unsupported requests before effects")[A valid schema outside the selected provider profile fails explicitly. Unsupported requested features must not be silently discarded.]
  ])

  #pending-ledger(
    pending-entry(title: "Resolve stream read authority", kind: "ruling", since: "2026-10-06", adr: [#adr(7)])[
      The public Stream documentation permits only the creating process to read, while the owner accepts reads from other processes and allows one pending read. Settle which read authority the public contract promises.
    ],
    pending-entry(title: "Specify richer provider-native generation", kind: "ruling", since: "2026-10-06", adr: [#adr(6)])[
      Sequential and parallel tool mode, tool choice, richer native options, optional injected model capabilities, provider-hosted tool outcomes, richer response blocks and typed extension payloads are unspecified. Native options cover credentials, account and version fields; adding a request field requires a complete custom adapter. A concrete advanced consumer must exist before a narrow provider option or an admitted request extension is chosen.
    ],
    pending-entry(title: "Specify advanced interaction lifecycles", kind: "ruling", since: "2026-10-06", adr: [#adr(6)])[
      Richer audio and video, embeddings, realtime and WebSockets, provider batch and background work, interrupted-stream resumption and optional remote cancellation acknowledgement need distinct protocol, state, ownership and compatibility contracts. They are not generation guarantees.
    ],
    pending-entry(title: "Carry Anthropic thinking through tool rounds", kind: "ruling", since: "2026-11-18", adr: [#adr(20)])[
      Anthropic requires a tool-requesting turn's thinking blocks and signatures to be sent back with its tool results. The assistant turn does not keep them, so preparation refuses a thinking level on Anthropic while a tool round continues. Settle how the turn's replay data carries the blocks.
    ],
    pending-entry(title: "Replay OpenAI reasoning without stored responses", kind: "ruling", since: "2026-11-19", adr: [#adr(21)])[
      Under store false, OpenAI returns a turn's reasoning only as encrypted content the request asks for with include reasoning.encrypted_content, and expects it back before the tool calls it preceded. The OpenAI reducer keeps no reasoning item and the assistant turn has no place for one, so a tool round without stored responses works but the model loses its earlier reasoning. Settle this with the Anthropic thinking replay, which needs the same place in the turn's replay data.
    ],
    pending-entry(title: "Decide the OpenAI store default", kind: "ruling", since: "2026-11-19", adr: [#adr(21)])[
      openai.with_store sends store explicitly; without it the field is left out and OpenAI stores the response. LLM Wire never reads a stored response, so false could become the default. Flipping it silently changes existing callers' stored data, so it waits for the next breaking release.
    ],
    pending-entry(title: "Check carried-over usage claims against code", kind: "verify", since: "2026-10-17", adr: [#adr(17)])[
      The defaults and timer composition under Effect timing and deadlines, the extension rules under Provider interpretation and the retry guidance under Failure and retry evidence came from retired guides. The compiled usage examples exercise the defaults, conversation persistence, failure kinds, offline testing, observation and client ownership. The remaining statements in those sections are not yet checked against code.
    ],
  )

  #section(title: "Generation admission", lead: "A reusable prepared value binds one encoded request to its output decoder.", body: [
    #subsection(title: "Values and refinements")[
      #entity(id: "generation-request", title: "Generation request", description: [The caller's explicit request and desired native output.], kind: "value-object", owner: "caller", lifecycle: "immutable", domain: "generation")[
        #attribute(name: "Input", type: "model string and ordered List(Message)", provenance: "authored")[Messages hold system/user text, user content parts, assistant turns, assistant content parts or tool results. Content parts are text, remote image URL, inline MIME/base64 image or inline file with MIME type, file name and base64 data.]
        #attribute(name: "Options", type: "optional maximum tokens, temperature, top-p, thinking level and cache reference; stop list", provenance: "authored")[Maximum tokens is positive; temperature is within 0 through 2; top-p within 0 through 1. Model/output name is trimmed and nonempty. Cache references are nonempty and provider-specific.]
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
      #answers(title: "Reusable generation settings", responsibility: [Retain generation controls independently of a conversation.], interface: [generation.Settings contains optional maximum output tokens, temperature, top-p, thinking level, stop sequences and one provider cache reference. generation.default leaves optional controls absent and stop sequences empty. with_generation replaces all controls; existing request setters update the same canonical settings.], interactions: [Request retains model, messages, settings, tools and output independently. Preparation derives the provider.Request field-label view; a custom adapter reads each control by label, the thinking level included, and refuses from its encoder what it cannot carry.], invariants: [Settings contain no model identity, messages, tools, credentials, output codec or runtime state. Changing output type or appending conversation preserves settings. Anthropic's default output bound remains an encoding choice.], failure: [Construction does not validate provider compatibility. Existing prepare checks reject invalid controls before encoding or HTTP execution.])
      #behavior(title: "Generation settings have replacement semantics", area: "Preparation", level: "interface")[#given[A request has generation controls.] #when[The caller applies a Settings value.] #then[All generation controls equal that value.] #then[Model, conversation, tools and output remain unchanged.]]
      #points([A scalar request setter after with_generation overrides only its named control. Applying generation.default later clears all explicit controls. #adr(11)])
      #answers(title: "Thinking level", responsibility: [Carry the caller's bound on model thinking to the provider in that provider's own form.], interface: [generation.with_thinking_level sets one thinking.Level: Minimal, Low, Medium, High, ExtraHigh or Max, each a value at least two built-in providers share. Usage reports thought tokens beside output tokens.], interactions: [OpenAI writes the level as its reasoning effort, Google as its thinking level and Anthropic as adaptive thinking with an effort that shares one output configuration object with any structured-output format; #adr(20) tables each level's wire value. A custom adapter reads provider.Request.thinking_level.], invariants: [A level is never dropped: a built-in adapter writes it or preparation refuses it, and a model that rejects the value it receives answers with its own status. The library keeps no model table. On every built-in provider the output limit bounds thought and visible tokens together, so a caller can guarantee only that total; a level steers how much of it thinking takes and reserves no visible share. Usage then shows how the limit was spent.], failure: [InvalidRequest(ThinkingUnsupported) names the problem: Max for Google, Minimal for Anthropic, or any level for Anthropic while the conversation's last assistant message is an assistant turn with a tool call, provider or application written. A model's rejection is a Status failure.])
      #points(
        [Anthropic needs the thinking blocks and signatures of a tool-requesting turn sent back with its results, which the library does not carry; hence the tool-round refusal above. Preparation cannot see thinking a model does by default without a level; that conversation reaches the provider unchanged.],
        [Anthropic's default output bound, used when the caller sets no maximum, stays the encoding's choice and is small; a level that thinks within it can leave little visible output, so a caller setting a level on Anthropic sets a maximum. Anthropic's own rules on sampling controls while thinking are its to enforce and answer with its status.],
        [A token budget is deferred until a caller is on a model that takes only a budget. It would arrive as its own setter and request field, so adding it breaks nothing. #adr(20)],
      )
      #behavior(title: "A thinking level reaches the provider in its own form", area: "Preparation", level: "interface")[
        #given[A built-in provider has a value for the request's thinking level.]
        #when[The caller prepares a request with that level.]
        #then[The encoded body carries that value in the provider's thinking field.]
        #then[A request without a level is encoded as before, with no thinking field.]
      ]
      #behavior(title: "A level the provider cannot carry is refused", area: "Preparation", level: "interface")[
        #given[The selected provider has no value for the level, or Anthropic thinking would continue a tool round.]
        #when[Preparation checks the level against the provider and the conversation.]
        #then[Preparation fails with ThinkingUnsupported naming the problem.]
        #then[Nothing reaches the network.]
      ]
      #behavior(title: "A model's rejection of the level stays visible", area: "Preparation", level: "interface")[
        #given[The provider has a value for the level and the chosen model rejects it.]
        #when[The prepared request executes.]
        #then[The call fails with the provider's status.]
      ]
      #answers(title: "Generation preparation", responsibility: [Validate and encode one request without networking.], interface: [prepare(Config, Request(o)) returns Prepared(o) or PrepareError; request_json reads the encoded body without credentials.], interactions: [Uses adapter validation, endpoint admission, tools, schema projection and the caller's output codec.], invariants: [Selected provider, admitted contracts and native decoder remain together. Invalid local values never reach HTTP.], failure: [InvalidSetting, InvalidRequest, UnsupportedSchema, ToolResultMismatch or RequestTooLarge name the refused boundary. Diagnostic strings are not classification keys.])
      #points(
        [Each built-in provider is selected by its constructor and configuration function (OpenAI, Anthropic, Google), and an endpoint override selects a compatible server.],
        [Built-in settings hold their keys behind reveal closures. OpenAI adds organization/project and an optional store flag, sent as store on every Responses request when set and left out otherwise; Anthropic adds API version; Google adds API version. Common settings own limits, three time bounds and tool-call checking. All bounds must be positive unless an explicit timeout Infinity is selected.],
        [Preparation validates timeouts, adapter settings, positive limits, trimmed nonempty model, historical turns, unique tool names and projected tool/output schemas. It then validates endpoint and common/provider options, calls the encoder, reveals and validates provider headers, validates the joined path and bounds the encoded body.],
        [Generation endpoint admission requires HTTP(S), a host, an admitted port and a path without userinfo, query, fragment or controls. The joined endpoint and encoded path must start with `/` and cannot inject a new authority, controls, spaces, a fragment or a second query. Before the query it refuses `\`, `;`, empty segments other than a trailing one, `.` and `..` segments, and percent-encoding that is malformed or decodes to `/`, `\`, `.`, `%`, a control byte or a non-ASCII byte. The Google adapter places the model in the request path, so its model must be one model-id segment of ASCII letters, digits, `.`, `-`, `_` and `:` other than `.` or `..`; any other model is InvalidSetting(Model). The OpenAI and Anthropic adapters send the model only in the body. Header names/values and reserved common headers are checked; credentials remain inspection-safe but the application must govern logging of prompt bodies.],
        [OpenAI refuses stop sequences. Thinking levels follow the Thinking level unit above. Anthropic and Google admit finite stop lists, with Google's maximum five. OpenAI admits remote image URLs; Anthropic and Google require inline image content. An inline file is OpenAI input_file with its file name and a base64 data URL, Google inlineData and Anthropic a base64 document titled with its file name; Anthropic admits only application/pdf. An inline file whose media type is an image is sent exactly as an inline image, without its name, on every provider. An inline image's media type is not checked. OpenAI function tools are sent with strict false, so the caller's schema is used as given and arguments reach the caller verbatim. #adr(21) Cache references are OpenAI prompt_cache_key or Google cachedContent; other providers reject them.],
        [Custom projection/encoding/header callbacks run synchronously during preparation. Their declared purity excludes networking and uncontrolled effects; the type system cannot enforce that promise. Generation header values are captured during prepare, so changing credentials requires preparing again.],
      )
      #behavior(title: "A file part reaches the provider as a file", area: "Preparation", level: "interface")[
        #given[A user message holds an inline file.]
        #when[Preparation encodes the message for a built-in provider.]
        #then[The encoded body carries the file in the provider's file form with its data, and with its name where the provider has a field for one.]
        #then[An image media type is sent as the provider's image, as an inline image would be.]
        #then[Anthropic refuses a media type that is neither application/pdf nor an image with FileTypeUnsupported, before anything is sent.]
      ]
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
        [OpenAI/Anthropic output], [record root; closed nested objects, lists, nullable, enums, integers/ranges and nested tagged union; an optional property is sent required and nullable], [non-record root, pair, number range, any, unknown kind],
        [Google output], [record root; also optional fields, pair, number range and any below root], [non-record root and unknown kind],
        [Custom adapter], [its explicit projection callbacks; Blueprint's canonical schema by default], [whatever its projection returns as unsupported],
      ))
      #points(
        [Nested Blueprint unions become anyOf of closed variant objects; each tag is a one-element string enum. The original codec still decodes the response, so this projection cannot bless a different native value. Google's field is generationConfig.responseJsonSchema; tool declarations use parametersJsonSchema. Anthropic documents that enum and const capitalization is not guaranteed, so the codec's decoding is the final check on a tag. #adr(4) records protocol-specific evidence.],
        [tool.new is for authored declarations and panics with the tool name when its name/schema is invalid. Runtime from_contract/from_json_schema returns ToolError. Tool names match ASCII letters, digits, underscore or hyphen, with length 1 through 64. Schema-only MCP input needs no Relay type or runtime dependency.],
        [The strict projection lists every property in required and turns an optional property's schema into anyOf of null and that schema, Blueprint's nullable form; a property already nullable keeps its schema. It applies to nested records, list items and union payloads. Google's projection keeps optional properties optional. #adr(21)],
        [Before validation, for every provider, the parsed answer is walked against the output schema and a null member is removed where the property is optional and its schema admits no null, being neither nullable nor any. A null there can only mean absence and the original codec refuses it. Answer text and InvalidOutput text are the cleaned JSON, written compactly with exact numbers in schema property order, when a member was removed, and the provider's text otherwise, including text that is not JSON. #adr(21)],
        [Schema-only admission inherits Blueprint's supported profile and loader failures. It is not general JSON Schema support; unsupported external MCP schemas remain explicitly refused. Native tool arguments and final output are parsed within byte bounds, validated against the original contract, then decoded. Schema-invalid values never enter codec mapping callbacks.],
      )
      #behavior(title: "A null for an optional field reads as absent", area: "Output validation", level: "interface")[
        #given[A structured request's codec has an optional property whose schema admits no null.]
        #when[The answer holds null for that property, at any depth.]
        #then[The member is removed before validation and the codec decodes the property as absent.]
        #then[Answer text is the cleaned JSON, which the original codec decodes to the same output.]
        #then[A null for a nullable property, or for a required one, is left for validation as before.]
      ]
      #behavior(title: "Unusable structured output retains its evidence", area: "Output validation", level: "interface")[
        #given[An admitted structured request receives final text that is malformed JSON, schema-invalid or rejected by its codec.]
        #when[The completed output is decoded for the caller.]
        #then[The result is InvalidOutput with the answer text, cleaned of nulls for optional fields when it is JSON, and typed ValueFailure.]
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
      [message.to_json/decoder uses llm_wire.message.v1; turn_to_json/turn_decoder uses llm_wire.turn.v1. A missing format tag is read as version 1; a different tag is rejected. turn_replay_to_json stores provider/id/data alone; its decoder takes separately stored text/calls and ignores an obsolete issues member in Fabric records.],
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
        [Usage is optional. Output tokens count every generated token, thoughts included, on every built-in provider; thought tokens hold the provider's thought count where it reports one and are otherwise None. Google's output is its candidate count plus its thought count, a count Google leaves out reading as zero. Each usage report replaces the previous one: Anthropic cumulative output updates replace the prior total rather than being summed, and Google/OpenAI report their own final or updated counts. No provider usage parity is claimed for cache billing. #adr(20)],
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
        [Anthropic Messages], [content block index routes text/thinking/tool_use; thinking is reasoning progress and never answer text, signatures and redacted thinking are accepted and not kept; tool_use.id is application id; result is user tool_result; system text is separate], [message_stop requires completed blocks; max_tokens is output-limited; refusal stop is ContentFiltered; server_tool_use is tracked separately from application calls],
        [Google GenerateContent], [model path streamGenerateContent with SSE; functionCall ids are retained or locally synthesized; model/user parts carry signed replay content], [STOP completes; MAX_TOKENS is partial; promptFeedback and safety finish reasons become ContentFiltered; provider errors and unknown stop reasons fail explicitly],
      ))
      #points(
        [OpenAI unknown named events produce bounded ProviderExtension. Anthropic ping produces no progress and unknown named events produce extensions. Google reduction reads its JSON payload rather than relying on named SSE events. Usage/extension/ping activity cannot end the first-progress wait.],
        [Provider-hosted actions can already have effects. Anthropic server-tool observation and ambiguous tool activity strengthen internal uncertainty; these do not authorize application dispatch. A public structured provider-hosted outcome remains an explicit pending contract.],
        [Generation wire JSON uses standard Gleam JSON; duplicate-member rejection is not universally promised for provider envelopes. Tool/output schema values use Blueprint so exact schema numbers do not pass through a Float bridge. #adr(4) and #adr(5) distinguish profile support from measured provider evidence.],
      )
    ]
    #behavior(title: "Usage separates thought tokens", area: "Provider reduction", level: "interface")[
      #given[A provider reports usage for a response.]
      #when[The reducer accepts the usage, as progress or with the outcome.]
      #then[Output tokens count every generated token, thoughts included.]
      #then[Thought tokens hold the provider's thought count, or None when the provider reports none.]
    ]
    #behavior(title: "An output-limited result shows how the limit was spent", area: "Provider reduction", level: "interface")[
      #given[The output limit ends a response that thought, even one with no visible output, and the provider reported usage.]
      #when[The caller receives OutputLimited.]
      #then[Its usage shows the tokens generated against the limit and, where the provider reports a thought count, how many of them were thought.]
    ]
    #behavior(title: "Anthropic thinking is read as reasoning", area: "Provider reduction", level: "interface")[
      #given[An Anthropic response contains thinking or redacted thinking blocks.]
      #when[The reducer reads them.]
      #then[Thinking text arrives as reasoning progress and is not part of the answer text.]
      #then[The response ends with the outcome its other blocks and stop reason decide.]
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
      (from: "owner", to: "worker", relation: "dependency", label: "lifetime + one credit / read to end"),
      (from: "worker", to: "body", relation: "call", label: "open / next / bounded read / close scope"),
      (from: "worker", to: "owner", relation: "dataflow", label: "one chunk then wait / body released"),
      (from: "owner", to: "framer", relation: "call", label: "admit / interpret"),
    ), caption: [The stream handle names the owner. The worker alone opens and reads the HTTP body; cancellation covers its whole scope.],
  ), body: [
    #subsection(title: "Borrowed HTTP client")[
      #points(
        [The application starts one HTTP Gun client at startup, passes it to every run and stream, and owns its whole lifetime; generation never starts or stops it. A client supervised under a name stays valid across restarts.],
        [A prepared generation can execute more than once and each execution starts a new owner and call identifier. Whether to execute again is the caller's decision.],
      )
    ]
    #subsection(title: "State and delivery")[
      #state-type(id: "stream-state", title: "Stream state", variants: ("unstarted", "open", "reading-to-end", "terminal-pending", "ended"))
      #entity(id: "stream-execution", title: "Stream execution", description: [One authoritative process for one started generation.], kind: "aggregate", owner: "stream owner", lifecycle: "stateful", domain: "execution")[
        #attribute(id: "state", name: "State", type: "Stream state", provenance: "derived", state-type: "stream-state", state-machine: "stream-lifecycle")[The terminal slot latches the first outcome. Accepted queued progress precedes that terminal unless explicit local close ends delivery.]
        #attribute(name: "Delivery", type: "bounded FIFO, one optional pending read and read identity", provenance: "derived")[Count/byte counters track the FIFO. Read timeout arbitration decides whether cancellation or delivery won; waiting readers are monitored.]
        #attribute(name: "Resource and evidence", type: "transport port, credit, timer handles, monotone evidence, last usage", provenance: "derived")[Creator death cancels the call. The transport-closed flag guards normal-path local cleanup.]
        #relates(cardinality: "1 : 1")[Each started owner holds one linked transport worker and one private reducer.]
      ]
      #state-machine(id: "stream-lifecycle", subject: "stream-execution", state-field: "state", state-type: "stream-state", title: "The HTTP body ends before the outcome is delivered", initial: "unstarted", accepting: ("ended",), states: ("unstarted", "open", "reading-to-end", "terminal-pending", "ended"), transitions: (("unstarted", "open", "start succeeds"), ("unstarted", "ended", "startup failure"), ("open", "open", "accepted progress / timed-out read"), ("open", "reading-to-end", "provider terminal"), ("open", "terminal-pending", "end of body / failure before the terminal / timer"), ("reading-to-end", "reading-to-end", "timed-out read"), ("reading-to-end", "terminal-pending", "end of body / bound passed / transport failure"), ("terminal-pending", "ended", "deliver terminal"), ("open", "ended", "close / creator death"), ("reading-to-end", "ended", "close / creator death"), ("terminal-pending", "ended", "close / creator death")), caption: [Reading to the end latches the outcome and delivers queued progress, but not the outcome. Close or a normal creator exit during it still hands the latched outcome to a reader already waiting; an abnormal creator exit ends the owner through their link. Terminal pending retains queued progress but no live HTTP scope. There is no transition back to open; a prepared value starts a new owner.])
      #answers(title: "Read and close protocol", responsibility: [Serialize delivery and terminate locally when requested.], interface: [stream returns before HTTP headers; next waits, next_within adds a local wait, collect discards progress; close returns Closed, or AlreadyEnded once an outcome is latched, whether or not it was delivered.], interactions: [Reads share one owner and FIFO. Close latches cancellation; pending-reader death clears only its read. Creating-caller death releases the whole execution.], invariants: [One pending read; one terminal; copied handles share closure. A read timeout leaves the stream readable.], failure: [ReadError is StreamEnded, ConcurrentRead, OwnerGone or TimedOut. Owner startup fails as Stopped/NotSent; loss while collecting returns conservative Stopped/MaybeSent evidence.])
      #answers(title: "Reading to the end", responsibility: [Finish the HTTP body of an outcome already latched at the provider terminal, so the exchange completes and its connection can be reused.], interface: [The owner asks the worker to read to the end; the worker answers once it has left its HTTP scope.], interactions: [The trailing-read bound is one deadline of 1 s set when the worker starts reading, and 64 KiB of trailing bytes; the time includes HTTP Gun's recording writes. The worker reads with HTTP Gun's bounded read under the call's request deadline, which already carries the whole-call and application deadlines. The owner replaces its generation timers at the latch with one backstop timer beyond the bound. Terminal is observed at the latch and Cleanup at the release.], invariants: [Applies to every outcome decided at or after the provider terminal: an answer, refusal, tool batch, output limit, provider-reported failure or a failure found while admitting the terminal. The outcome is delivered only after the worker's answer; queued progress is delivered meanwhile. Trailing bytes reach neither framer nor reducer and count toward no other limit.], failure: [Past the bound, on an oversize trailing chunk or on a read failure the worker closes the body before it answers and the latched outcome stands; an HTTP Gun recording then stores a cut-off ending. If the worker has not answered by the backstop, the owner requests the close and delivers. Close and creator death request the close at once; the body then ends asynchronously, as for any close. A worker that exits abnormally ends the owner through their link, as at any other point. The outcome can arrive up to the bound later than the terminal, so a caller whose own read budget ends inside that wait and then closes loses an answer the provider completed.])
      #points(
        [The owner accepts cross-process reads and rejects another pending reader; its public comment declares creator-only reads. Lifetime ownership and read authority are distinct. The pending ruling preserves this conflict.],
        [Close and owner exit settle against pending delivery. A terminal already delivered wins, and a reader already waiting when close or a normal creator exit ends reading-to-end receives the latched outcome. After close, later reads report StreamEnded. Repeated close is idempotent even when the owner has exited. A queued provider terminal cannot be replaced by late HTTP events.],
        [A provider terminal always precedes the end of the body, because the worker reads the end only after the owner grants credit. A terminal the reducer decides only at the end of the body has nothing left to read. Events framed before a framing failure in the same chunk are interpreted before the failure: their progress is delivered first, and a provider terminal among them latches the outcome, which the failure then does not replace. Events after a provider terminal are dropped and later chunks are read uninterpreted. The size limits that judge a whole chunk, ChunkBytes and ResponseBodyBytes, still judge that chunk with its trailing bytes and fail it before the terminal. #adr(19) records the bound and the choice to delay the outcome rather than outlive the call.],
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
      #behavior(title: "A completed response is read to the end of its body", area: "Body ending", level: "boundary")[
        #given[A provider terminal arrived before the end of the response body.]
        #when[The body ends within the bound.]
        #then[The response is received to its end, as a complete exchange, before the outcome is delivered.]
        #then[The outcome is the one decided at the provider terminal.]
      ]
      #behavior(title: "Only the outcome waits for the end of the body", area: "Body ending", level: "interface")[
        #given[A caller reads a stream whose provider terminal arrived before the end of the body.]
        #when[The caller reads while the rest of the body is outstanding.]
        #then[Progress accepted before the terminal is delivered without waiting.]
        #then[The outcome is delivered once the body ends or reading it stops.]
      ]
      #behavior(title: "A body that does not end in time is closed", area: "Body ending", level: "boundary")[
        #given[A provider terminal arrived and the rest of the body is outstanding.]
        #when[The time or byte bound passes, or reading fails, including on the whole-call or application deadline.]
        #then[Local transport closes and the caller receives the outcome decided at the provider terminal.]
      ]
      #behavior(title: "Bytes after the terminal never change the outcome", area: "Body ending", level: "boundary")[
        #given[The body carries more bytes after the provider terminal, in its chunk or in later chunks, including further events and malformed bytes.]
        #when[The owner reads them.]
        #then[They are discarded uninterpreted and raise no failure.]
      ]
      #behavior(title: "Close ends the wait for the end of the body", area: "Body ending", level: "interface")[
        #given[A stream is reading the rest of its body after a provider terminal.]
        #when[A caller closes a handle or the creating process exits.]
        #then[The close of local transport is requested at once and close reports that the stream had already ended.]
        #then[A reader already waiting receives the outcome decided at the provider terminal, unless the creating process ended abnormally.]
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
        [terminal], [provider terminal: the worker reads the rest of the body within the trailing-read bound, then leaves its scope and the outcome is delivered; failure before the terminal or timer: close immediately; queued delivery may follow], [outcome up to the trailing-read bound later than the terminal; no remote rollback or cancellation guarantee; a body that outlasts the bound is closed and the outcome stands],
        [structured decoding], [caller-side output validation after semantic terminal and HTTP cleanup], [InvalidOutput; synchronous codec callback has no independent preemption],
      ))
      #points(
        [WholeCall defaults to 600 seconds. FirstToken defaults to 180 seconds; it begins during owner setup, after reducer factory and transport initializer work, and ends at the first accepted semantic progress. IdleGap defaults to 60 seconds after that point. Infinity lifts each independently. Preparation and caller retry waiting are outside these timers.],
        [Generation establishes one absolute whole-call deadline before setup. The owner uses its remaining duration, and HTTP opening replaces the relative request timeout with the remaining duration at dispatch. An explicit deadline on the supplied HTTP client remains a ceiling, including when WholeCall is Infinity. Generation lifts HTTP idle; connect and pool admission bounds still apply. #adr(10) records the distinction between a default timeout and an explicit deadline. Synchronous custom factory/reducer/output callbacks are trusted code and may delay observing elapsed time.],
        [For HTTPS, the supplied client's destination policy remains. For admitted plaintext, the implementation configures default destination policy with loopback/private admission and PlaintextToLoopbackOnly through with_destination. HTTP Gun combines view constraints; this setup is not a claim that a caller's refusal can always be overridden or merely narrowed. Resolved non-loopback plaintext remains refused.],
        [Status 200 requires text/event-stream and absent/identity encoding. Other status bodies are bounded by ErrorBodyBytes and retained as Status with Retry-After; body/stream errors preserve independent observed-byte evidence. HTTP Gun does not add retries, redirects or decompression to this path.],
      )
      #behavior(title: "An application deadline constrains generation", area: "Deadlines", level: "boundary")[
        #given[The supplied client has an explicit absolute deadline.]
        #when[Generation opens or consumes its response.]
        #then[The earlier of the application deadline and the whole-call deadline bounds the provider interaction.]
        #then[An expired application deadline refuses submission with NotSent evidence.]
        #then[Expiry closes local response resources while preserving observed send, progress and usage evidence.]
        #then[The caller retains ownership of the supplied client.]
      ]
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
      [error.kind classifies every error into the closed set Transport, ProviderError, ContentPolicy, UnusableResponse, OverLimit and Ended. The set gains no variants, so a caller's exhaustive match stays complete.],
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
    #behavior(title: "The retry consumer bounds active work and waiting", area: "Retry consumer", level: "interface")[
      #given[The caller supplies a prepared interaction, finite total duration, maximum attempts and fallback delay.]
      #when[The consumer executes its retry loop.]
      #then[The consumer admits positive attempts and a total budget of 1 through 4,294,967,295 whole milliseconds, within the BEAM receive timeout range. Invalid budgets or negative fallback fail locally without starting a call.]
      #then[One monotonic deadline accounts for calls and waits. Each stream read uses the remaining duration; expiry closes the owned stream and returns an application deadline error without claiming provider rollback.]
      #then[A provider delay or fallback that cannot fit before the deadline returns the original typed provider failure without shortening the wait or starting another call.]
      #then[The supplied client remains caller-owned. Startup, read-timeout arbitration and cleanup retain their own runtime bounds. Synchronous extension callbacks are not preempted; the budget does not promise an exact return-time ceiling. #adr(12) records this boundary.]
    ]
  ])
]
