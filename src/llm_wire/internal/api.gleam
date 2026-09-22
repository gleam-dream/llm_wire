import gleam/dynamic/decode
import gleam/erlang/process
import gleam/erlang/reference
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Gt, Lt}
import gleam/result
import gleam/string
import json/blueprint/codec
import json/blueprint/runtime
import llm_wire/internal/owner
import llm_wire/internal/provider_config
import llm_wire/internal/schema
import llm_wire/internal/stream_types
import llm_wire/internal/transport_failure
import llm_wire/telemetry
import llm_wire/types

/// A provider-bound request whose options and Blueprint tool schemas have been
/// checked locally. It retains the original adapter configuration so callers
/// cannot switch providers while preparing a continuation.
pub opaque type PreparedCall {
  PreparedCall(
    config: provider_config.ProviderConfig,
    provider: types.Provider,
    model: types.ModelId,
    request: types.Request,
    host: String,
    port: Int,
    path: String,
    tls_mode: provider_config.TlsMode,
    headers: List(#(String, String)),
    body: String,
    structured_format: Option(StructuredFormat),
    origin: reference.Reference,
  )
}

pub opaque type Continuation {
  Continuation(
    provider: types.Provider,
    model: types.ModelId,
    expected_calls: List(types.CallId),
    source_calls: List(types.ToolCall),
    conversation: List(types.Message),
    response_id: Option(String),
    provider_continuation: Option(stream_types.ProviderContinuation),
    origin: reference.Reference,
  )
}

pub fn continuation_response_id(continuation: Continuation) -> Option(String) {
  continuation.response_id
}

pub type RunResult {
  RunText(text: String, usage: Option(types.Usage))
  RunToolCalls(
    calls: List(types.ToolCall),
    continuation: Continuation,
    usage: Option(types.Usage),
  )
  RunOutputLimited(
    partial_text: String,
    partial_calls: List(types.ToolCall),
    usage: Option(types.Usage),
  )
  RunRefusal(reason: String)
}

type StructuredFormat {
  StructuredFormat(name: String, schema: json.Json)
}

pub opaque type PreparedStructuredCall(output) {
  PreparedStructuredCall(
    prepared: PreparedCall,
    contract: runtime.RuntimeContract,
    output_codec: codec.Codec(output),
  )
}

pub type StructuredRunResult(output) {
  StructuredValue(output: output, raw_json: String, usage: Option(types.Usage))
  StructuredNeedsTools(
    calls: List(types.ToolCall),
    continuation: Continuation,
    usage: Option(types.Usage),
  )
  StructuredOutputLimited(
    partial_text: String,
    partial_calls: List(types.ToolCall),
    usage: Option(types.Usage),
  )
  StructuredRefusal(reason: String)
}

pub fn structured_request_json(
  prepared: PreparedStructuredCall(output),
) -> String {
  prepared.prepared.body
}

pub fn prepared_provider(prepared: PreparedCall) -> types.Provider {
  prepared.provider
}

pub fn prepared_path(prepared: PreparedCall) -> String {
  prepared.path
}

pub fn prepared_tls_mode(prepared: PreparedCall) -> provider_config.TlsMode {
  prepared.tls_mode
}

pub fn prepared_request_json(prepared: PreparedCall) -> String {
  prepared.body
}

pub fn prepared_tools(prepared: PreparedCall) -> List(types.ToolDefinition) {
  prepared.request.tools
}

type GunSetupError {
  GunFailure(String)
  GunStatus(Int, String, String)
}

type GunHandle

@external(erlang, "llm_wire_gun_ffi", "connect_and_stream_gleam")
fn gun_connect_and_stream_with_pool(
  pool: Option(process.Pid),
  host: String,
  port: Int,
  path: String,
  headers: List(#(String, String)),
  body: String,
  overall_timeout_ms: Int,
  tls_mode: String,
  ca_file: String,
  max_header_bytes: Int,
  max_chunk_bytes: Int,
  owner_pid: process.Pid,
  on_chunk: fn(BitArray) -> Nil,
  on_eof: fn() -> Nil,
  on_error: fn(String) -> Nil,
  on_request_sent: fn() -> Nil,
) -> Result(GunHandle, GunSetupError)

@external(erlang, "llm_wire_gun_ffi", "send_request_more")
fn gun_request_more(handle: GunHandle) -> Nil

@external(erlang, "llm_wire_gun_ffi", "send_close")
fn gun_close(handle: GunHandle) -> Nil

@external(erlang, "llm_wire_gun_ffi", "handle_pid")
fn gun_handle_pid(handle: GunHandle) -> process.Pid

/// Starts the exact provider request captured by preparation. This low-level
/// entry accepts no caller-supplied HTTP body, route, or headers.
pub fn connect_prepared_and_stream(
  prepared: PreparedCall,
  overall_timeout_ms: Int,
  tls_mode: provider_config.TlsMode,
  max_header_bytes: Int,
  max_chunk_bytes: Int,
  owner_pid: process.Pid,
  on_chunk: fn(BitArray) -> Nil,
  on_eof: fn() -> Nil,
  on_error: fn(String) -> Nil,
  on_request_sent: fn() -> Nil,
) -> Result(#(owner.TransportPort, process.Pid), types.WireError) {
  connect_prepared_and_stream_with_pool(
    None,
    prepared,
    overall_timeout_ms,
    tls_mode,
    max_header_bytes,
    max_chunk_bytes,
    owner_pid,
    on_chunk,
    on_eof,
    on_error,
    on_request_sent,
  )
}

pub fn connect_prepared_and_stream_with_pool(
  pool_pid: Option(process.Pid),
  prepared: PreparedCall,
  overall_timeout_ms: Int,
  tls_mode: provider_config.TlsMode,
  max_header_bytes: Int,
  max_chunk_bytes: Int,
  owner_pid: process.Pid,
  on_chunk: fn(BitArray) -> Nil,
  on_eof: fn() -> Nil,
  on_error: fn(String) -> Nil,
  on_request_sent: fn() -> Nil,
) -> Result(#(owner.TransportPort, process.Pid), types.WireError) {
  use Nil <- result.try(validate_prepared_transport(prepared, tls_mode))
  let #(tls_name, ca_file) = case tls_mode {
    provider_config.Plaintext -> #("plaintext", "")
    provider_config.VerifySystem -> #("verify_system", "")
    provider_config.VerifyCaFile(path) -> #("verify_ca_file", path)
  }
  case
    gun_connect_and_stream_with_pool(
      pool_pid,
      prepared.host,
      prepared.port,
      prepared.path,
      prepared.headers,
      prepared.body,
      overall_timeout_ms,
      tls_name,
      ca_file,
      max_header_bytes,
      max_chunk_bytes,
      owner_pid,
      on_chunk,
      on_eof,
      on_error,
      on_request_sent,
    )
  {
    Error(GunStatus(status, response_body, retry_after)) ->
      Error(types.HttpStatusError(
        status,
        response_body,
        parse_retry_hint(retry_after),
      ))
    Error(GunFailure(reason)) -> Error(transport_failure.classify(reason))
    Ok(handle) ->
      Ok(#(
        owner.TransportPort(
          request_more: fn() { gun_request_more(handle) },
          close: fn() { gun_close(handle) },
        ),
        gun_handle_pid(handle),
      ))
  }
}

pub fn validate_prepared_transport(
  prepared: PreparedCall,
  tls_mode: provider_config.TlsMode,
) -> Result(Nil, types.WireError) {
  let host = prepared.host
  let path = prepared.path
  let valid_host =
    host != ""
    && !string.contains(host, "/")
    && !string.contains(host, "@")
    && !string.contains(host, "\r")
    && !string.contains(host, "\n")
  let valid_path =
    string.starts_with(path, "/")
    && !string.contains(path, "\r")
    && !string.contains(path, "\n")
    && !string.contains(path, " ")
  let host_is_local =
    host == "localhost" || host == "127.0.0.1" || host == "::1"
  let tls_policy_is_valid = case tls_mode {
    provider_config.Plaintext | provider_config.VerifyCaFile(_) -> host_is_local
    provider_config.VerifySystem -> True
  }
  use Nil <- result.try(
    case
      valid_host
      && valid_path
      && prepared.port > 0
      && prepared.port <= 65_535
      && tls_policy_is_valid
    {
      True -> Ok(Nil)
      False ->
        Error(types.ConfigurationError(
          "Client requires valid HTTP fields; remote hosts require system-verified HTTPS",
        ))
    },
  )
  validate_headers(prepared.headers)
}

fn parse_retry_hint(value: String) -> Option(types.RetryHint) {
  case value {
    "" -> None
    _ ->
      case int.parse(value) {
        Ok(seconds) if seconds >= 0 -> Some(types.RetryDelaySeconds(seconds))
        Ok(_) -> Some(types.RetryHeaderValue(value))
        Error(Nil) -> Some(types.RetryHeaderValue(value))
      }
  }
}

pub fn prepare(
  config: provider_config.ProviderConfig,
  request: types.Request,
  limits: types.Limits,
) -> Result(PreparedCall, types.WireError) {
  prepare_with_format(config, request, limits, None, None)
}

pub fn prepare_structured(
  config: provider_config.ProviderConfig,
  request: types.Request,
  limits: types.Limits,
  output_name: String,
  output_codec: codec.Codec(output),
) -> Result(PreparedStructuredCall(output), types.WireError) {
  let name = string.trim(output_name)
  case name == "" {
    True ->
      Error(types.PreparationError("Structured output name cannot be empty"))
    False ->
      case codec.schema(output_codec) {
        Error(_) ->
          Error(types.PreparationError("Structured output codec has no schema"))
        Ok(output_schema) -> {
          use schema_json <- result.try(case config_provider(config) {
            types.Google -> schema.google_strict_output_schema(output_schema)
            _ -> schema.strict_output_schema(output_schema)
          })
          use contract <- result.try(case runtime.from_schema(output_schema) {
            Ok(value) -> Ok(value)
            Error(error) ->
              Error(types.PreparationError(
                "Structured output schema cannot be admitted: "
                <> string.inspect(error),
              ))
          })
          let format = StructuredFormat(name, schema_json)
          use prepared <- result.try(prepare_with_format(
            config,
            request,
            limits,
            Some(format),
            None,
          ))
          Ok(PreparedStructuredCall(prepared, contract, output_codec))
        }
      }
  }
}

pub fn prepare_structured_continue(
  prepared: PreparedStructuredCall(output),
  continuation: Continuation,
  results: List(types.ToolResult),
  limits: types.Limits,
) -> Result(PreparedStructuredCall(output), types.WireError) {
  use next_call <- result.try(prepare_continue(
    prepared.prepared,
    continuation,
    results,
    limits,
  ))
  Ok(PreparedStructuredCall(next_call, prepared.contract, prepared.output_codec))
}

pub fn structured_prepared_call(
  prepared: PreparedStructuredCall(output),
) -> PreparedCall {
  prepared.prepared
}

pub fn decode_structured_output(
  prepared: PreparedStructuredCall(output),
  raw_json: String,
) -> Result(output, types.WireError) {
  schema.validate_and_decode_structured_output(
    prepared.contract,
    prepared.output_codec,
    raw_json,
  )
}

fn prepare_with_format(
  config: provider_config.ProviderConfig,
  request: types.Request,
  limits: types.Limits,
  structured_format: Option(StructuredFormat),
  provider_continuation: Option(stream_types.ProviderContinuation),
) -> Result(PreparedCall, types.WireError) {
  use admitted_tools <- result.try(types.admit_tool_catalog(request.tools))
  use endpoint_parts <- result.try(parse_endpoint(config_endpoint(config)))
  use Nil <- result.try(validate_options(request))
  let provider = config_provider(config)
  use Nil <- result.try(validate_provider_options(provider, request))
  use tool_json <- result.try(encode_tools(provider, admitted_tools))
  let body = case config {
    provider_config.OpenAIConfig(..) -> {
      use encoded <- result.try(encode_openai_request(
        request,
        tool_json,
        structured_format,
      ))
      Ok(json.to_string(encoded))
    }
    provider_config.AnthropicConfig(..) ->
      encode_anthropic_request(request, tool_json, structured_format)
    provider_config.GoogleConfig(..) ->
      encode_google_request(
        request,
        tool_json,
        structured_format,
        provider_continuation,
      )
  }
  use body_text <- result.try(body)
  let #(host, port, base_path, tls_mode) = endpoint_parts
  use provider_path <- result.try(case provider {
    types.OpenAI -> Ok("/responses")
    types.Anthropic -> Ok("/messages")
    types.Google ->
      Ok(
        "/models/"
        <> types.model_id_to_string(request.model)
        <> ":streamGenerateContent?alt=sse",
      )
  })
  let path = base_path <> provider_path
  let headers =
    request_headers(provider, config_api_key(config), config_headers(config))
  case validate_headers(headers) {
    Error(error) -> Error(error)
    Ok(Nil) -> {
      // Schema and argument limits are checked before transport. The captured
      // request is otherwise immutable once preparation succeeds.
      let body_bytes = string.byte_size(body_text)
      case body_bytes > limits.event_bytes_limit {
        True ->
          Error(types.ResourceLimitExceeded(
            "request_bytes_limit",
            limits.event_bytes_limit,
            body_bytes,
          ))
        False -> {
          let prepared =
            PreparedCall(
              config,
              provider,
              request.model,
              types.Request(..request, tools: admitted_tools),
              host,
              port,
              path,
              tls_mode,
              headers,
              body_text,
              structured_format,
              reference.new(),
            )
          let _ =
            telemetry.observe(
              telemetry.Prepared,
              provider_name(provider),
              "accepted",
            )
          Ok(prepared)
        }
      }
    }
  }
}

pub fn next(
  stream: owner.Stream,
  timeout_ms: Int,
) -> Result(stream_types.ReadResult, types.ReadError) {
  owner.next(stream, timeout_ms)
}

pub fn close(
  stream: owner.Stream,
) -> Result(types.CloseOutcome, types.ReadError) {
  owner.close(stream)
}

/// Validates exact tool-result coverage before preparing a provider-bound
/// follow-up call. Results may arrive in any order; the wire transcript follows
/// the provider's original outstanding-call order.
pub fn prepare_continue(
  prepared: PreparedCall,
  continuation: Continuation,
  results: List(types.ToolResult),
  limits: types.Limits,
) -> Result(PreparedCall, types.WireError) {
  case
    continuation.origin == prepared.origin
    && continuation.provider == prepared.provider
    && continuation.model == prepared.model
  {
    False ->
      Error(types.PreparationError(
        "Continuation belongs to a different prepared interaction",
      ))
    True -> {
      let source_calls = continuation.source_calls
      case
        source_calls == []
        || list.map(source_calls, fn(call) { call.id })
        != continuation.expected_calls
      {
        True ->
          Error(types.PreparationError(
            "Continuation is stale or missing its original tool calls",
          ))
        False -> {
          use Nil <- result.try(validate_continuation_calls(
            source_calls,
            prepared.request.tools,
            limits.argument_bytes_per_call_limit,
          ))
          use ordered <- result.try(validate_tool_results(
            continuation.expected_calls,
            results,
          ))
          let messages =
            list.append(continuation.conversation, [
              types.AssistantToolCalls(source_calls),
              ..list.map(ordered, fn(tool_result) {
                types.ToolResultMessage(
                  tool_result.call_id,
                  tool_result.content,
                )
              })
            ])
          let request =
            types.new_request(continuation.model, messages)
            |> types.with_tools(prepared.request.tools)
            |> copy_options(prepared.request)
          prepare_with_format(
            prepared.config,
            request,
            limits,
            prepared.structured_format,
            continuation.provider_continuation,
          )
        }
      }
    }
  }
}

fn validate_continuation_calls(
  calls: List(types.ToolCall),
  tools: List(types.ToolDefinition),
  max_argument_bytes: Int,
) -> Result(Nil, types.WireError) {
  list.fold(calls, Ok(Nil), fn(acc, call) {
    use Nil <- result.try(acc)
    let name = types.tool_name_to_string(call.name)
    case
      list.find(tools, fn(tool) {
        types.tool_name_to_string(types.tool_name_of(tool)) == name
      })
    {
      Error(Nil) ->
        Error(types.PreparationError(
          "Continuation call names an unadmitted tool: " <> name,
        ))
      Ok(tool) ->
        types.validate_tool_arguments(
          tool,
          max_argument_bytes,
          call.arguments_json,
        )
    }
  })
}

fn copy_options(
  request: types.Request,
  original: types.Request,
) -> types.Request {
  let with_max = case original.max_tokens {
    Some(value) -> types.with_max_tokens(request, value)
    None -> request
  }
  let with_temperature = case original.temperature {
    Some(value) -> types.with_temperature(with_max, value)
    None -> with_max
  }
  let with_top_p = case original.top_p {
    Some(value) -> types.with_top_p(with_temperature, value)
    None -> with_temperature
  }
  let with_stops =
    types.with_stop_sequences(with_top_p, original.stop_sequences)
  case original.prompt_cache {
    Some(cache) -> types.with_prompt_cache(with_stops, cache)
    None -> with_stops
  }
}

fn validate_tool_results(
  expected: List(types.CallId),
  results: List(types.ToolResult),
) -> Result(List(types.ToolResult), types.WireError) {
  let empty: Result(List(types.ToolResult), types.WireError) = Ok([])
  use checked <- result.try(
    list.fold(results, empty, fn(acc, tool_result) {
      use seen <- result.try(acc)
      let id = types.call_id_to_string(tool_result.call_id)
      case list.contains(expected, tool_result.call_id) {
        False -> Error(types.PreparationError("Unknown tool result: " <> id))
        True ->
          case
            list.any(seen, fn(item: types.ToolResult) {
              item.call_id == tool_result.call_id
            })
          {
            True ->
              Error(types.PreparationError("Duplicate tool result: " <> id))
            False -> Ok(list.append(seen, [tool_result]))
          }
      }
    }),
  )
  case
    list.find(expected, fn(id) {
      !list.any(checked, fn(item) { item.call_id == id })
    })
  {
    Ok(missing) ->
      Error(types.PreparationError(
        "Missing tool result: " <> types.call_id_to_string(missing),
      ))
    Error(Nil) ->
      list.fold(expected, Ok([]), fn(acc, id) {
        use ordered <- result.try(acc)
        case list.find(checked, fn(item) { item.call_id == id }) {
          Ok(item) -> Ok(list.append(ordered, [item]))
          Error(Nil) ->
            Error(types.PreparationError(
              "Missing tool result: " <> types.call_id_to_string(id),
            ))
        }
      })
  }
}

pub fn collect_run(
  stream: owner.Stream,
  prepared: PreparedCall,
  read_timeout_ms: Int,
) -> Result(RunResult, types.WireError) {
  case owner.next(stream, read_timeout_ms) {
    Error(types.ReadTimeout) -> collect_run(stream, prepared, read_timeout_ms)
    Error(types.StreamClosed) ->
      Error(types.TransportError("Stream closed before a terminal result"))
    Error(types.ConcurrentReadConflict) ->
      Error(types.ConfigurationError(
        "Buffered runner lost exclusive stream ownership",
      ))
    Error(types.OwnerUnavailable) ->
      Error(types.TransportError("Stream owner unavailable"))
    Ok(stream_types.NextProgress(_progress)) ->
      collect_run(stream, prepared, read_timeout_ms)
    Ok(stream_types.StreamTerminal(terminal)) ->
      terminal_result(prepared, terminal)
  }
}

/// Session implementation helper. Callers must pair a terminal with the
/// prepared interaction that opened its stream.
@internal
pub fn terminal_result(
  prepared: PreparedCall,
  terminal: stream_types.TerminalOutcome,
) -> Result(RunResult, types.WireError) {
  case terminal {
    stream_types.StreamFinished(stream_types.CompletedText(text), usage) ->
      Ok(RunText(text, usage))
    stream_types.StreamFinished(
      stream_types.CompletedToolCalls(_text, calls, response_id),
      usage,
    ) -> {
      let continuation =
        Continuation(
          prepared.provider,
          prepared.model,
          list.map(calls, fn(call) { call.id }),
          calls,
          prepared.request.messages,
          response_id,
          None,
          prepared.origin,
        )
      Ok(RunToolCalls(calls, continuation, usage))
    }
    stream_types.StreamFinished(
      stream_types.CompletedToolCallsWithContinuation(
        _text,
        calls,
        response_id,
        provider_continuation,
      ),
      usage,
    ) -> {
      let continuation =
        Continuation(
          prepared.provider,
          prepared.model,
          list.map(calls, fn(call) { call.id }),
          calls,
          prepared.request.messages,
          response_id,
          Some(provider_continuation),
          prepared.origin,
        )
      Ok(RunToolCalls(calls, continuation, usage))
    }
    stream_types.StreamFinished(stream_types.OutputLimited(text, calls), usage) ->
      Ok(RunOutputLimited(text, calls, usage))
    stream_types.StreamFinished(stream_types.Refused(reason), _usage) ->
      Ok(RunRefusal(reason))
    stream_types.StreamFailed(error, _retry) -> Error(error)
    stream_types.StreamCancelledLocally(_) -> Error(types.CancelledLocally)
  }
}

fn config_provider(config: provider_config.ProviderConfig) -> types.Provider {
  case config {
    provider_config.OpenAIConfig(..) -> types.OpenAI
    provider_config.AnthropicConfig(..) -> types.Anthropic
    provider_config.GoogleConfig(..) -> types.Google
  }
}

fn provider_name(provider: types.Provider) -> String {
  case provider {
    types.OpenAI -> "openai"
    types.Anthropic -> "anthropic"
    types.Google -> "google"
  }
}

fn config_endpoint(config: provider_config.ProviderConfig) -> types.Endpoint {
  case config {
    provider_config.OpenAIConfig(endpoint:, ..) -> endpoint
    provider_config.AnthropicConfig(endpoint:, ..) -> endpoint
    provider_config.GoogleConfig(endpoint:, ..) -> endpoint
  }
}

fn config_api_key(config: provider_config.ProviderConfig) -> types.ApiKey {
  case config {
    provider_config.OpenAIConfig(api_key:, ..) -> api_key
    provider_config.AnthropicConfig(api_key:, ..) -> api_key
    provider_config.GoogleConfig(api_key:, ..) -> api_key
  }
}

fn config_headers(
  config: provider_config.ProviderConfig,
) -> List(#(String, String)) {
  case config {
    provider_config.OpenAIConfig(organization:, project:, ..) -> {
      let org = case organization {
        Some(value) -> [#("OpenAI-Organization", value)]
        None -> []
      }
      let proj = case project {
        Some(value) -> [#("OpenAI-Project", value)]
        None -> []
      }
      list.append(org, proj)
    }
    provider_config.AnthropicConfig(version:, ..) ->
      case version {
        Some(value) -> [#("anthropic-version", value)]
        None -> []
      }
    provider_config.GoogleConfig(api_version:, ..) ->
      case api_version {
        Some(value) -> [#("x-goog-api-version", value)]
        None -> []
      }
  }
}

fn request_headers(
  provider: types.Provider,
  api_key: types.ApiKey,
  additional_headers: List(#(String, String)),
) -> List(#(String, String)) {
  let common = [
    #("Content-Type", "application/json"),
    #("Accept", "text/event-stream"),
    #("Accept-Encoding", "identity"),
  ]
  case provider {
    types.OpenAI -> [
      #("Authorization", "Bearer " <> types.api_key_expose(api_key)),
      ..list.append(additional_headers, common)
    ]
    types.Anthropic -> {
      let has_version =
        list.any(additional_headers, fn(header) {
          string.lowercase(header.0) == "anthropic-version"
        })
      let version_header = case has_version {
        True -> []
        False -> [#("anthropic-version", "2023-06-01")]
      }
      [
        #("x-api-key", types.api_key_expose(api_key)),
        ..list.append(additional_headers, list.append(version_header, common))
      ]
    }
    types.Google -> [
      #("x-goog-api-key", types.api_key_expose(api_key)),
      ..list.append(additional_headers, common)
    ]
  }
}

fn validate_headers(
  headers: List(#(String, String)),
) -> Result(Nil, types.WireError) {
  case
    list.any(headers, fn(header) {
      string.trim(header.0) == ""
      || string.contains(header.0, "\r")
      || string.contains(header.0, "\n")
      || string.contains(header.1, "\r")
      || string.contains(header.1, "\n")
    })
  {
    True -> Error(types.PreparationError("Invalid provider header"))
    False -> Ok(Nil)
  }
}

fn validate_options(request: types.Request) -> Result(Nil, types.WireError) {
  case request.prompt_cache {
    Some(types.OpenAiPromptCacheKey(key)) ->
      case string.trim(key) == "" {
        True ->
          Error(types.PreparationError(
            "OpenAI prompt_cache_key cannot be empty",
          ))
        False -> validate_sampling_options(request)
      }
    Some(types.GoogleCachedContent(name)) ->
      case string.trim(name) == "" {
        True ->
          Error(types.PreparationError("Google cachedContent cannot be empty"))
        False -> validate_sampling_options(request)
      }
    None -> validate_sampling_options(request)
  }
}

fn validate_sampling_options(
  request: types.Request,
) -> Result(Nil, types.WireError) {
  case request.max_tokens {
    Some(value) if value <= 0 ->
      Error(types.PreparationError("max_tokens must be positive"))
    _ ->
      case request.temperature {
        Some(value) ->
          case in_float_range(value, 0.0, 2.0) {
            False ->
              Error(types.PreparationError(
                "temperature must be between 0 and 2",
              ))
            True -> validate_top_p(request.top_p)
          }
        None -> validate_top_p(request.top_p)
      }
  }
}

fn validate_top_p(top_p: Option(Float)) -> Result(Nil, types.WireError) {
  case top_p {
    Some(value) ->
      case in_float_range(value, 0.0, 1.0) {
        True -> Ok(Nil)
        False -> Error(types.PreparationError("top_p must be between 0 and 1"))
      }
    None -> Ok(Nil)
  }
}

fn validate_provider_options(
  provider: types.Provider,
  request: types.Request,
) -> Result(Nil, types.WireError) {
  case provider {
    types.OpenAI -> {
      use Nil <- result.try(case request.prompt_cache {
        None | Some(types.OpenAiPromptCacheKey(_)) -> Ok(Nil)
        Some(types.GoogleCachedContent(_)) ->
          Error(types.PreparationError(
            "Google cachedContent cannot be used with the OpenAI profile",
          ))
      })
      case list.is_empty(request.stop_sequences) {
        True -> Ok(Nil)
        False ->
          Error(types.PreparationError(
            "stop_sequences are not supported by the Responses profile",
          ))
      }
    }
    types.Google ->
      case request.prompt_cache {
        None | Some(types.GoogleCachedContent(_)) ->
          case list.length(request.stop_sequences) > 5 {
            True ->
              Error(types.PreparationError(
                "Google GenerationConfig.stopSequences accepts at most 5 values",
              ))
            False -> Ok(Nil)
          }
        Some(types.OpenAiPromptCacheKey(_)) ->
          Error(types.PreparationError(
            "OpenAI prompt_cache_key cannot be used with the Google profile",
          ))
      }
    types.Anthropic ->
      case request.prompt_cache {
        None -> Ok(Nil)
        Some(_) ->
          Error(types.PreparationError(
            "prompt caching is not admitted by the Anthropic profile",
          ))
      }
  }
}

fn in_float_range(value: Float, minimum: Float, maximum: Float) -> Bool {
  float.compare(value, with: minimum) != Lt
  && float.compare(value, with: maximum) != Gt
}

fn encode_tools(
  provider: types.Provider,
  tools: List(types.ToolDefinition),
) -> Result(List(json.Json), types.WireError) {
  list.fold(tools, Ok([]), fn(acc, tool) {
    use prior <- result.try(acc)
    use parameters <- result.try(case provider {
      types.Google ->
        schema.google_function_parameters_schema(types.tool_schema(tool))
      _ -> schema.provider_schema(types.tool_schema(tool))
    })
    let name = json.string(types.tool_name_to_string(types.tool_name_of(tool)))
    let description = json.string(types.tool_description(tool))
    use encoded <- result.try(case provider {
      types.OpenAI ->
        Ok(
          json.object([
            #("type", json.string("function")),
            #("name", name),
            #("description", description),
            #("parameters", parameters),
          ]),
        )
      types.Anthropic ->
        Ok(
          json.object([
            #("name", name),
            #("description", description),
            #("input_schema", parameters),
          ]),
        )
      types.Google ->
        Ok(
          json.object([
            #("name", name),
            #("description", description),
            #("parametersJsonSchema", parameters),
          ]),
        )
    })
    Ok(list.append(prior, [encoded]))
  })
}

fn encode_openai_request(
  request: types.Request,
  tools: List(json.Json),
  structured_format: Option(StructuredFormat),
) -> Result(json.Json, types.WireError) {
  let empty: Result(List(json.Json), types.WireError) = Ok([])
  use input_items <- result.try(
    list.fold(request.messages, empty, fn(acc, message) {
      use prior <- result.try(acc)
      Ok(list.append(prior, openai_message_items(message)))
    }),
  )
  let base = [
    #("model", json.string(types.model_id_to_string(request.model))),
    #("input", json.array(input_items, fn(value) { value })),
    #("stream", json.bool(True)),
  ]
  let options = request_option_fields(request, types.OpenAI)
  let tool_fields = case tools {
    [] -> []
    _ -> [#("tools", json.array(tools, fn(value) { value }))]
  }
  let format_fields = openai_output_format(structured_format)
  Ok(
    json.object(list.append(
      base,
      list.append(options, list.append(tool_fields, format_fields)),
    )),
  )
}

fn encode_anthropic_request(
  request: types.Request,
  tools: List(json.Json),
  structured_format: Option(StructuredFormat),
) -> Result(String, types.WireError) {
  let system =
    list.filter_map(request.messages, fn(message) {
      case message {
        types.SystemMessage(content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
    |> string.join("\n")
  let empty: Result(List(String), types.WireError) = Ok([])
  use messages <- result.try(
    list.fold(request.messages, empty, fn(acc, message) {
      use encoded <- result.try(acc)
      case message {
        types.SystemMessage(_) -> Ok(encoded)
        _ -> {
          use message_json <- result.try(anthropic_message_json(message))
          Ok(list.append(encoded, [message_json]))
        }
      }
    }),
  )
  let max_tokens = case request.max_tokens {
    Some(value) -> value
    None -> 1024
  }
  let base = [
    #(
      "model",
      json.to_string(json.string(types.model_id_to_string(request.model))),
    ),
    #("max_tokens", json.to_string(json.int(max_tokens))),
    #("messages", "[" <> string.join(messages, ",") <> "]"),
    #("stream", "true"),
  ]
  let system_field = case system {
    "" -> []
    value -> [#("system", json.to_string(json.string(value)))]
  }
  let tool_fields = case tools {
    [] -> []
    _ -> [#("tools", json.to_string(json.array(tools, fn(value) { value })))]
  }
  let options =
    list.map(request_option_fields(request, types.Anthropic), fn(field) {
      #(field.0, json.to_string(field.1))
    })
  let format_fields =
    list.map(anthropic_output_format(structured_format), fn(field) {
      #(field.0, json.to_string(field.1))
    })
  Ok(
    encode_object_text(list.append(
      base,
      list.append(
        system_field,
        list.append(options, list.append(tool_fields, format_fields)),
      ),
    )),
  )
}

fn encode_object_text(fields: List(#(String, String))) -> String {
  "{"
  <> string.join(
    list.map(fields, fn(field) {
      json.to_string(json.string(field.0)) <> ":" <> field.1
    }),
    ",",
  )
  <> "}"
}

fn encode_google_request(
  request: types.Request,
  tools: List(json.Json),
  structured_format: Option(StructuredFormat),
  provider_continuation: Option(stream_types.ProviderContinuation),
) -> Result(String, types.WireError) {
  let system_parts =
    list.filter_map(request.messages, fn(message) {
      case message {
        types.SystemMessage(content) ->
          Ok("{\"text\":" <> json.to_string(json.string(content)) <> "}")
        _ -> Error(Nil)
      }
    })
  let system_field = case system_parts {
    [] -> []
    parts -> [
      #("systemInstruction", "{\"parts\":[" <> string.join(parts, ",") <> "]}"),
    ]
  }

  use contents <- result.try(build_google_contents(
    request.messages,
    request.messages,
    provider_continuation,
  ))

  let base = [#("contents", "[" <> string.join(contents, ",") <> "]")]
  let cache_fields = case request.prompt_cache {
    Some(types.GoogleCachedContent(name)) -> [
      #("cachedContent", json.to_string(json.string(name))),
    ]
    _ -> []
  }

  let tool_fields = case tools {
    [] -> []
    _ -> [
      #(
        "tools",
        json.to_string(
          json.array(
            [
              json.object([
                #("functionDeclarations", json.array(tools, fn(t) { t })),
              ]),
            ],
            fn(v) { v },
          ),
        ),
      ),
    ]
  }

  let gen_config_field = case
    google_generation_config(request, structured_format)
  {
    Some(cfg) -> [#("generationConfig", json.to_string(cfg))]
    None -> []
  }

  Ok(
    encode_object_text(list.append(
      base,
      list.append(
        cache_fields,
        list.append(system_field, list.append(tool_fields, gen_config_field)),
      ),
    )),
  )
}

fn google_generation_config(
  request: types.Request,
  structured_format: Option(StructuredFormat),
) -> Option(json.Json) {
  let option_fields = request_option_fields(request, types.Google)
  let format_fields = case structured_format {
    Some(StructuredFormat(_, schema_json)) -> [
      #("responseMimeType", json.string("application/json")),
      #("responseSchema", schema_json),
    ]
    None -> []
  }
  let all_fields = list.append(option_fields, format_fields)
  case all_fields {
    [] -> None
    _ -> Some(json.object(all_fields))
  }
}

fn build_google_contents(
  messages: List(types.Message),
  all_messages: List(types.Message),
  provider_continuation: Option(stream_types.ProviderContinuation),
) -> Result(List(String), types.WireError) {
  let non_system =
    list.filter(messages, fn(m) {
      case m {
        types.SystemMessage(_) -> False
        _ -> True
      }
    })
  build_google_contents_loop(
    non_system,
    all_messages,
    [],
    provider_continuation,
  )
}

fn build_google_contents_loop(
  remaining: List(types.Message),
  all_messages: List(types.Message),
  acc: List(String),
  provider_continuation: Option(stream_types.ProviderContinuation),
) -> Result(List(String), types.WireError) {
  case remaining {
    [] -> Ok(acc)
    [types.ToolResultMessage(..), ..] -> {
      let #(tool_results, rest) =
        collect_consecutive_tool_results(remaining, [])
      use response_parts <- result.try(
        list.fold(tool_results, Ok([]), fn(p_acc, tr) {
          use parts_so_far <- result.try(p_acc)
          case tr {
            types.ToolResultMessage(call_id, content) -> {
              let tool_name = find_tool_call_name(all_messages, call_id)
              let response_json = case
                json.parse(content, decode.dict(decode.string, decode.dynamic))
              {
                Ok(_) -> content
                Error(_) ->
                  "{\"output\":" <> json.to_string(json.string(content)) <> "}"
              }
              let id_part = case
                find_tool_call_provider_id(all_messages, call_id)
              {
                None -> ""
                Some(provider_id) ->
                  ",\"id\":" <> json.to_string(json.string(provider_id))
              }
              let fr =
                "{\"name\":"
                <> json.to_string(json.string(tool_name))
                <> ",\"response\":"
                <> response_json
                <> id_part
                <> "}"
              let part = "{\"functionResponse\":" <> fr <> "}"
              Ok(list.append(parts_so_far, [part]))
            }
            _ -> Ok(parts_so_far)
          }
        }),
      )
      let turn =
        "{\"role\":\"user\",\"parts\":["
        <> string.join(response_parts, ",")
        <> "]}"
      build_google_contents_loop(
        rest,
        all_messages,
        list.append(acc, [turn]),
        provider_continuation,
      )
    }
    [message, ..rest] -> {
      let #(turn_result, remaining_continuation) = case
        provider_continuation,
        message
      {
        Some(stream_types.GoogleProviderContinuation(parts)),
          types.AssistantToolCalls(_)
        -> #(
          Ok(
            "{\"role\":\"model\",\"parts\":[" <> string.join(parts, ",") <> "]}",
          ),
          None,
        )
        _, _ -> #(single_google_turn(message), provider_continuation)
      }
      use turn <- result.try(turn_result)
      build_google_contents_loop(
        rest,
        all_messages,
        list.append(acc, [turn]),
        remaining_continuation,
      )
    }
  }
}

fn collect_consecutive_tool_results(
  messages: List(types.Message),
  acc: List(types.Message),
) -> #(List(types.Message), List(types.Message)) {
  case messages {
    [types.ToolResultMessage(..) as tr, ..rest] ->
      collect_consecutive_tool_results(rest, list.append(acc, [tr]))
    _ -> #(acc, messages)
  }
}

fn single_google_turn(
  message: types.Message,
) -> Result(String, types.WireError) {
  case message {
    types.SystemMessage(_) -> Ok("{}")
    types.UserMessage(content) ->
      Ok(
        "{\"role\":\"user\",\"parts\":[{\"text\":"
        <> json.to_string(json.string(content))
        <> "}]}",
      )
    types.UserContent(parts) -> {
      use encoded <- result.try(google_content_parts(parts))
      Ok("{\"role\":\"user\",\"parts\":[" <> string.join(encoded, ",") <> "]}")
    }
    types.AssistantMessage(content) ->
      Ok(
        "{\"role\":\"model\",\"parts\":[{\"text\":"
        <> json.to_string(json.string(content))
        <> "}]}",
      )
    types.AssistantContent(parts) -> {
      use encoded <- result.try(google_content_parts(parts))
      Ok("{\"role\":\"model\",\"parts\":[" <> string.join(encoded, ",") <> "]}")
    }
    types.AssistantToolCalls(calls) -> {
      let empty: Result(List(String), types.WireError) = Ok([])
      use parts <- result.try(
        list.fold(calls, empty, fn(acc, call) {
          use prior <- result.try(acc)
          use input <- result.try(canonical_json(call.arguments_json))
          let id_part = case call.provider_id {
            None -> ""
            Some(provider_id) ->
              ",\"id\":" <> json.to_string(json.string(provider_id))
          }
          let thought_signature_part = case call.provider_state {
            None -> ""
            Some(signature) ->
              ",\"thoughtSignature\":" <> json.to_string(json.string(signature))
          }
          let fc =
            "{\"name\":"
            <> json.to_string(json.string(types.tool_name_to_string(call.name)))
            <> ",\"args\":"
            <> input
            <> id_part
            <> "}"
          let part = "{\"functionCall\":" <> fc <> thought_signature_part <> "}"
          Ok(list.append(prior, [part]))
        }),
      )
      Ok("{\"role\":\"model\",\"parts\":[" <> string.join(parts, ",") <> "]}")
    }
    types.ToolResultMessage(..) -> Ok("{}")
  }
}

fn google_content_parts(
  parts: List(types.Content),
) -> Result(List(String), types.WireError) {
  list.fold(parts, Ok([]), fn(acc, part) {
    use prior <- result.try(acc)
    case part {
      types.TextContent(text) ->
        Ok(
          list.append(prior, [
            "{\"text\":" <> json.to_string(json.string(text)) <> "}",
          ]),
        )
      types.InlineImageContent(mime_type, base64_data) ->
        Ok(
          list.append(prior, [
            "{\"inlineData\":{\"mimeType\":"
            <> json.to_string(json.string(mime_type))
            <> ",\"data\":"
            <> json.to_string(json.string(base64_data))
            <> "}}",
          ]),
        )
      types.ImageUrlContent(_) ->
        Error(types.PreparationError(
          "Google content does not support image URLs; use inline image data",
        ))
    }
  })
}

fn find_tool_call_name(
  messages: List(types.Message),
  call_id: types.CallId,
) -> String {
  let found =
    list.find_map(messages, fn(msg) {
      case msg {
        types.AssistantToolCalls(calls) ->
          case list.find(calls, fn(c) { c.id == call_id }) {
            Ok(c) -> Ok(types.tool_name_to_string(c.name))
            Error(Nil) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  case found {
    Ok(name) -> name
    Error(Nil) -> types.call_id_to_string(call_id)
  }
}

fn find_tool_call_provider_id(
  messages: List(types.Message),
  call_id: types.CallId,
) -> Option(String) {
  let found =
    list.find_map(messages, fn(msg) {
      case msg {
        types.AssistantToolCalls(calls) ->
          case list.find(calls, fn(c) { c.id == call_id }) {
            Ok(c) -> Ok(c.provider_id)
            Error(Nil) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  case found {
    Ok(provider_id) -> provider_id
    Error(Nil) -> None
  }
}

fn anthropic_message_json(
  message: types.Message,
) -> Result(String, types.WireError) {
  case message {
    // System messages are lifted into the top-level system field by the
    // request encoder, but keeping this function total avoids a partial wire
    // conversion if the fold changes later.
    types.SystemMessage(_) -> Ok("{}")
    types.UserMessage(content) ->
      Ok(
        json.to_string(
          json.object([
            #("role", json.string("user")),
            #("content", json.string(content)),
          ]),
        ),
      )
    types.UserContent(parts) -> {
      use content <- result.try(anthropic_content_json(parts))
      Ok(
        json.to_string(
          json.object([
            #("role", json.string("user")),
            #("content", content),
          ]),
        ),
      )
    }
    types.AssistantMessage(content) ->
      Ok(
        json.to_string(
          json.object([
            #("role", json.string("assistant")),
            #("content", json.string(content)),
          ]),
        ),
      )
    types.AssistantContent(parts) -> {
      use content <- result.try(anthropic_content_json(parts))
      Ok(
        json.to_string(
          json.object([
            #("role", json.string("assistant")),
            #("content", content),
          ]),
        ),
      )
    }
    types.ToolResultMessage(call_id, content) ->
      Ok(
        json.to_string(
          json.object([
            #("role", json.string("user")),
            #(
              "content",
              json.array(
                [
                  json.object([
                    #("type", json.string("tool_result")),
                    #(
                      "tool_use_id",
                      json.string(types.call_id_to_string(call_id)),
                    ),
                    #("content", json.string(content)),
                  ]),
                ],
                fn(value) { value },
              ),
            ),
          ]),
        ),
      )
    types.AssistantToolCalls(calls) -> {
      let empty: Result(List(String), types.WireError) = Ok([])
      use blocks <- result.try(
        list.fold(calls, empty, fn(acc, call) {
          use prior <- result.try(acc)
          use input <- result.try(canonical_json(call.arguments_json))
          let block =
            "{\"type\":\"tool_use\",\"id\":"
            <> json.to_string(json.string(types.call_id_to_string(call.id)))
            <> ",\"name\":"
            <> json.to_string(json.string(types.tool_name_to_string(call.name)))
            <> ",\"input\":"
            <> input
            <> "}"
          Ok(list.append(prior, [block]))
        }),
      )
      Ok(
        "{\"role\":\"assistant\",\"content\":["
        <> string.join(blocks, ",")
        <> "]}",
      )
    }
  }
}

fn anthropic_content_json(
  parts: List(types.Content),
) -> Result(json.Json, types.WireError) {
  let empty: Result(List(json.Json), types.WireError) = Ok([])
  use encoded <- result.try(
    list.fold(parts, empty, fn(acc, part) {
      use prior <- result.try(acc)
      case part {
        types.TextContent(text) ->
          Ok(
            list.append(prior, [
              json.object([
                #("type", json.string("text")),
                #("text", json.string(text)),
              ]),
            ]),
          )
        types.InlineImageContent(mime_type, base64_data) ->
          Ok(
            list.append(prior, [
              json.object([
                #("type", json.string("image")),
                #(
                  "source",
                  json.object([
                    #("type", json.string("base64")),
                    #("media_type", json.string(mime_type)),
                    #("data", json.string(base64_data)),
                  ]),
                ),
              ]),
            ]),
          )
        types.ImageUrlContent(_) ->
          Error(types.PreparationError(
            "Anthropic image URL content is outside this adapter's admitted profile; use inline image data",
          ))
      }
    }),
  )
  Ok(json.array(encoded, fn(value) { value }))
}

fn canonical_json(raw: String) -> Result(String, types.WireError) {
  case json.parse(raw, decode.dynamic) {
    Error(_) ->
      Error(types.PreparationError(
        "Continuation contains invalid tool argument JSON",
      ))
    Ok(_) -> Ok(raw)
  }
}

fn openai_output_format(
  structured_format: Option(StructuredFormat),
) -> List(#(String, json.Json)) {
  case structured_format {
    None -> []
    Some(StructuredFormat(name, schema_json)) -> [
      #(
        "text",
        json.object([
          #(
            "format",
            json.object([
              #("type", json.string("json_schema")),
              #("name", json.string(name)),
              #("schema", schema_json),
              #("strict", json.bool(True)),
            ]),
          ),
        ]),
      ),
    ]
  }
}

fn anthropic_output_format(
  structured_format: Option(StructuredFormat),
) -> List(#(String, json.Json)) {
  case structured_format {
    None -> []
    Some(StructuredFormat(_, schema_json)) -> [
      #(
        "output_config",
        json.object([
          #(
            "format",
            json.object([
              #("type", json.string("json_schema")),
              #("schema", schema_json),
            ]),
          ),
        ]),
      ),
    ]
  }
}

fn request_option_fields(
  request: types.Request,
  provider: types.Provider,
) -> List(#(String, json.Json)) {
  let max_tokens = case request.max_tokens {
    Some(value) ->
      case provider {
        types.OpenAI -> [#("max_output_tokens", json.int(value))]
        types.Anthropic -> []
        types.Google -> [#("maxOutputTokens", json.int(value))]
      }
    None -> []
  }
  let temperature = case request.temperature {
    Some(value) -> [#("temperature", json.float(value))]
    None -> []
  }
  let top_p = case request.top_p {
    Some(value) ->
      case provider {
        types.Google -> [#("topP", json.float(value))]
        _ -> [#("top_p", json.float(value))]
      }
    None -> []
  }
  let stop = case request.stop_sequences, provider {
    [], _ -> []
    values, types.Anthropic -> [
      #("stop_sequences", json.array(values, json.string)),
    ]
    values, types.Google -> [
      #("stopSequences", json.array(values, json.string)),
    ]
    _, _ -> []
  }
  let cache = case request.prompt_cache, provider {
    Some(types.OpenAiPromptCacheKey(key)), types.OpenAI -> [
      #("prompt_cache_key", json.string(key)),
    ]
    _, _ -> []
  }
  list.append(
    max_tokens,
    list.append(temperature, list.append(top_p, list.append(stop, cache))),
  )
}

fn openai_message_items(message: types.Message) -> List(json.Json) {
  case message {
    types.SystemMessage(content) -> [
      json.object([
        #("role", json.string("system")),
        #("content", json.string(content)),
      ]),
    ]
    types.UserMessage(content) -> [
      json.object([
        #("role", json.string("user")),
        #("content", json.string(content)),
      ]),
    ]
    types.UserContent(parts) -> [
      json.object([
        #("role", json.string("user")),
        #(
          "content",
          json.array(openai_content_parts(parts, "input_text"), fn(value) {
            value
          }),
        ),
      ]),
    ]
    types.AssistantMessage(content) -> [
      json.object([
        #("role", json.string("assistant")),
        #("content", json.string(content)),
      ]),
    ]
    types.AssistantContent(parts) -> [
      json.object([
        #("role", json.string("assistant")),
        #(
          "content",
          json.array(openai_content_parts(parts, "output_text"), fn(value) {
            value
          }),
        ),
      ]),
    ]
    types.AssistantToolCalls(calls) ->
      list.map(calls, fn(call) {
        json.object([
          #("type", json.string("function_call")),
          #("call_id", json.string(types.call_id_to_string(call.id))),
          #("name", json.string(types.tool_name_to_string(call.name))),
          #("arguments", json.string(call.arguments_json)),
        ])
      })
    types.ToolResultMessage(call_id, content) -> [
      json.object([
        #("type", json.string("function_call_output")),
        #("call_id", json.string(types.call_id_to_string(call_id))),
        #("output", json.string(content)),
      ]),
    ]
  }
}

fn openai_content_parts(
  parts: List(types.Content),
  text_type: String,
) -> List(json.Json) {
  list.map(parts, fn(part) {
    case part {
      types.TextContent(text) ->
        json.object([
          #("type", json.string(text_type)),
          #("text", json.string(text)),
        ])
      types.ImageUrlContent(url) ->
        json.object([
          #("type", json.string("input_image")),
          #("image_url", json.string(url)),
        ])
      types.InlineImageContent(mime_type, base64_data) ->
        json.object([
          #("type", json.string("input_image")),
          #(
            "image_url",
            json.string("data:" <> mime_type <> ";base64," <> base64_data),
          ),
        ])
    }
  })
}

fn parse_endpoint(
  endpoint: types.Endpoint,
) -> Result(#(String, Int, String, provider_config.TlsMode), types.WireError) {
  let raw = types.endpoint_to_string(endpoint)
  use #(scheme, after_scheme) <- result.try(
    string.split_once(raw, "://")
    |> result.replace_error(types.ConfigurationError(
      "Endpoint must contain ://",
    )),
  )
  let #(authority, suffix) = case string.split_once(after_scheme, "/") {
    Ok(parts) -> parts
    Error(Nil) -> #(after_scheme, "")
  }
  case
    authority == ""
    || string.contains(authority, "@")
    || string.contains(suffix, "?")
    || string.contains(suffix, "#")
  {
    True ->
      Error(types.ConfigurationError("Endpoint authority or path is invalid"))
    False -> {
      let #(host, port) = case string.split_once(authority, ":") {
        Error(Nil) -> #(authority, case scheme {
          "https" -> 443
          "http" -> 80
          _ -> 0
        })
        Ok(#(host, port_text)) -> #(host, case int.parse(port_text) {
          Ok(value) -> value
          Error(Nil) -> 0
        })
      }
      let local_http = host == "localhost" || host == "127.0.0.1"
      case
        host == ""
        || port < 1
        || port > 65_535
        || scheme != "https"
        && scheme != "http"
        || scheme == "http"
        && !local_http
      {
        True ->
          Error(types.ConfigurationError(
            "Endpoint must use HTTPS (HTTP is allowed only for loopback tests) and a valid host/port",
          ))
        False -> {
          let base_path = case suffix {
            "" -> ""
            value -> "/" <> trim_trailing_slashes(value)
          }
          let tls_mode = case scheme {
            "https" -> provider_config.VerifySystem
            _ -> provider_config.Plaintext
          }
          Ok(#(host, port, base_path, tls_mode))
        }
      }
    }
  }
}

fn trim_trailing_slashes(path: String) -> String {
  case string.ends_with(path, "/") {
    True -> trim_trailing_slashes(string.drop_end(path, 1))
    False -> path
  }
}
