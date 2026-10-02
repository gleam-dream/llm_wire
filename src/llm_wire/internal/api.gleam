import gleam/bit_array
import gleam/dynamic/decode
import gleam/float
import gleam/http
import gleam/http/request as http_request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Gt, Lt}
import gleam/result
import gleam/string
import json/blueprint/codec
import json/blueprint/contract
import llm_wire/internal/anthropic
import llm_wire/internal/call_admission
import llm_wire/internal/google
import llm_wire/internal/json_bounds
import llm_wire/internal/openai
import llm_wire/internal/owner
import llm_wire/internal/schema
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/internal/tls
import llm_wire/provider
import llm_wire/telemetry
import llm_wire/types

/// A provider-bound request whose options and Blueprint tool schemas have been
/// checked locally. Configuration applies only to this request.
pub opaque type PreparedCall {
  PreparedCall(
    config: provider.Adapter,
    provider: types.Provider,
    model: types.ModelId,
    request: types.Request,
    host: String,
    port: Int,
    path: String,
    tls_mode: tls.TlsMode,
    // A closure, so the credential header never prints with the prepared call.
    headers: fn() -> List(#(String, String)),
    body: String,
    structured_format: Option(StructuredFormat),
  )
}

pub type RunResult {
  RunText(text: String, usage: Option(types.Usage))
  RunToolCalls(turn: types.AssistantTurn, usage: Option(types.Usage))
  RunOutputLimited(
    partial_text: String,
    partial_calls: List(types.ToolCall),
    usage: Option(types.Usage),
  )
  RunRefusal(reason: String, usage: Option(types.Usage))
}

type StructuredFormat {
  StructuredFormat(name: String, schema: json.Json)
}

pub opaque type PreparedStructuredCall(output) {
  PreparedStructuredCall(
    prepared: PreparedCall,
    contract: contract.Contract,
    output_codec: codec.Codec(output),
    limits: types.Limits,
  )
}

pub type StructuredRunResult(output) {
  StructuredValue(output: output, raw_json: String, usage: Option(types.Usage))
  StructuredNeedsTools(turn: types.AssistantTurn, usage: Option(types.Usage))
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

pub fn prepared_tls_mode(prepared: PreparedCall) -> tls.TlsMode {
  prepared.tls_mode
}

pub fn prepared_request_json(prepared: PreparedCall) -> String {
  prepared.body
}

/// Only the admitted representation can enter HTTP execution. Never re-encode
/// an unvalidated request or expose credential-bearing headers publicly.
pub fn http_request(prepared: PreparedCall) -> http_request.Request(BitArray) {
  let parts = string.split_once(prepared.path, "?")
  let #(path, query) = case parts {
    Ok(#(path, query)) -> #(path, Some(query))
    Error(Nil) -> #(prepared.path, None)
  }
  http_request.Request(
    method: http.Post,
    scheme: case prepared.tls_mode {
      tls.Plaintext -> http.Http
      _ -> http.Https
    },
    host: prepared.host,
    port: Some(prepared.port),
    path: path,
    query: query,
    headers: list.map(prepared.headers(), fn(h) {
      #(string.lowercase(h.0), h.1)
    }),
    body: bit_array.from_string(prepared.body),
  )
}

/// The admitted request this call encodes, for the scripted test transport.
pub fn prepared_request(prepared: PreparedCall) -> types.Request {
  prepared.request
}

pub fn prepared_tools(prepared: PreparedCall) -> List(types.ToolDefinition) {
  prepared.request.tools
}

pub fn prepared_adapter(
  prepared: PreparedCall,
) -> Result(provider.Adapter, types.WireError) {
  Ok(prepared.config)
}

pub fn validate_prepared_transport(
  prepared: PreparedCall,
  tls_mode: tls.TlsMode,
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
    tls.Plaintext -> host_is_local
    tls.VerifySystem -> True
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
          "Client requires valid HTTP fields; remote hosts require verified HTTPS",
        ))
    },
  )
  // Provider headers were admitted before the fixed HTTP/SSE headers were
  // appended. The prepared request is opaque and cannot add headers later.
  Ok(Nil)
}

pub fn prepare(
  config: provider.Adapter,
  request: types.Request,
  limits: types.Limits,
) -> Result(PreparedCall, types.WireError) {
  prepare_with_format(config, request, limits, None)
}

pub fn prepare_structured(
  config: provider.Adapter,
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
          use schema_json <- result.try(provider.project_output_schema(
            config,
            output_schema,
          ))
          use output_contract <- result.try(
            contract.from_schema(output_schema)
            |> result.map_error(fn(error) {
              types.PreparationError(
                "Structured output schema cannot be admitted: "
                <> codec.describe_definition_error(error),
              )
            }),
          )
          let format = StructuredFormat(name, schema_json)
          use prepared <- result.try(prepare_with_format(
            config,
            request,
            limits,
            Some(format),
          ))
          Ok(PreparedStructuredCall(
            prepared,
            output_contract,
            output_codec,
            limits,
          ))
        }
      }
  }
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
    case
      prepared.limits.text_bytes_per_block_limit
      < prepared.limits.total_text_bytes_limit
    {
      True -> prepared.limits.text_bytes_per_block_limit
      False -> prepared.limits.total_text_bytes_limit
    },
  )
}

fn prepare_with_format(
  config: provider.Adapter,
  request: types.Request,
  limits: types.Limits,
  structured_format: Option(StructuredFormat),
) -> Result(PreparedCall, types.WireError) {
  let adapter = config
  use messages <- result.try(admit_messages(
    request.messages,
    provider.identity(adapter),
    limits,
  ))
  let request = types.Request(..request, messages: messages)
  use admitted_tools <- result.try(types.admit_tool_catalog(request.tools))
  use projected_tools <- result.try(
    list.fold(admitted_tools, Ok([]), fn(acc, tool) {
      use prior <- result.try(acc)
      use schema_json <- result.try(provider.project_tool_schema(
        adapter,
        types.tool_schema(tool),
      ))
      Ok(
        list.append(prior, [
          provider.ProjectedTool(
            types.tool_name_of(tool),
            types.tool_description(tool),
            schema_json,
          ),
        ]),
      )
    }),
  )
  use endpoint_parts <- result.try(parse_endpoint(provider.endpoint(adapter)))
  use Nil <- result.try(validate_options(request))
  let identity = provider.identity(adapter)
  use Nil <- result.try(validate_provider_options(identity, request))
  let format = case structured_format {
    Some(StructuredFormat(name, schema_json)) ->
      Some(provider.OutputFormat(name, schema_json))
    None -> None
  }
  use encoded <- result.try(provider.encode(
    adapter,
    request,
    projected_tools,
    format,
  ))
  let provider.EncodedRequest(provider_path, body_text) = encoded
  let #(host, port, base_path, tls_mode) = endpoint_parts
  let path = base_path <> provider_path
  let provider_headers = provider.reveal_headers(adapter)
  let headers = list.append(provider_headers, common_headers())
  case validate_headers(provider_headers) {
    Error(error) -> Error(error)
    Ok(Nil) -> {
      // Schema and argument limits are checked before transport. The captured
      // request is otherwise immutable once preparation succeeds.
      let body_bytes = string.byte_size(body_text)
      case body_bytes > limits.request_bytes_limit {
        True ->
          Error(types.ResourceLimitExceeded(
            "request_bytes_limit",
            limits.request_bytes_limit,
            body_bytes,
          ))
        False -> {
          let prepared =
            PreparedCall(
              config,
              identity,
              request.model,
              types.Request(..request, tools: admitted_tools),
              host,
              port,
              path,
              tls_mode,
              fn() { headers },
              body_text,
              structured_format,
            )
          use Nil <- result.try(validate_prepared_transport(prepared, tls_mode))
          let _ =
            telemetry.observe(
              telemetry.Prepared,
              provider_name(identity),
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
      stream_types.CompletedToolCalls(text, calls, response_id, issues),
      usage,
    ) ->
      Ok(RunToolCalls(
        types.AssistantTurn(
          prepared.provider,
          text,
          calls,
          response_id,
          None,
          issues,
        ),
        usage,
      ))
    stream_types.StreamFinished(
      stream_types.CompletedToolCallsWithData(
        text,
        calls,
        response_id,
        data,
        issues,
      ),
      usage,
    ) ->
      Ok(RunToolCalls(
        types.AssistantTurn(
          prepared.provider,
          text,
          calls,
          response_id,
          Some(data),
          issues,
        ),
        usage,
      ))
    stream_types.StreamFinished(stream_types.OutputLimited(text, calls), usage) ->
      Ok(RunOutputLimited(text, calls, usage))
    stream_types.StreamFinished(stream_types.Refused(reason), usage) ->
      Ok(RunRefusal(reason, usage))
    stream_types.StreamFailed(error, _retry) -> Error(error)
    stream_types.StreamCancelledLocally(_) -> Error(types.CancelledLocally)
  }
}

fn provider_name(provider: types.Provider) -> String {
  case provider {
    types.OpenAI -> "openai"
    types.Anthropic -> "anthropic"
    types.Google -> "google"
    types.Custom(name) -> name
  }
}

fn request_headers(
  identity: types.Provider,
  api_key: types.ApiKey,
  additional_headers: List(#(String, String)),
) -> List(#(String, String)) {
  case identity {
    types.OpenAI -> [
      #("Authorization", "Bearer " <> types.reveal_api_key(api_key)),
      ..additional_headers
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
        #("x-api-key", types.reveal_api_key(api_key)),
        ..list.append(additional_headers, version_header)
      ]
    }
    types.Google -> [
      #("x-goog-api-key", types.reveal_api_key(api_key)),
      ..additional_headers
    ]
    types.Custom(_) -> additional_headers
  }
}

fn common_headers() -> List(#(String, String)) {
  [
    #("Content-Type", "application/json"),
    #("Accept", "text/event-stream"),
    #("Accept-Encoding", "identity"),
  ]
}

fn validate_headers(
  headers: List(#(String, String)),
) -> Result(Nil, types.WireError) {
  case
    list.any(headers, fn(header) {
      let name = string.lowercase(header.0)
      name == "content-type"
      || name == "accept"
      || name == "accept-encoding"
      || string.trim(header.0) == ""
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
    types.Custom(_) -> Ok(Nil)
  }
}

fn in_float_range(value: Float, minimum: Float, maximum: Float) -> Bool {
  float.compare(value, with: minimum) != Lt
  && float.compare(value, with: maximum) != Gt
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

  use contents <- result.try(build_google_contents(request.messages))

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
) -> Result(List(String), types.WireError) {
  let non_system =
    list.filter(messages, fn(m) {
      case m {
        types.SystemMessage(_) -> False
        _ -> True
      }
    })
  build_google_contents_loop(non_system, [], [])
}

fn build_google_contents_loop(
  remaining: List(types.Message),
  preceding_turn: List(types.Message),
  acc: List(String),
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
              let tool_name = find_tool_call_name(preceding_turn, call_id)
              let response_json = case
                json.parse(content, decode.dict(decode.string, decode.dynamic))
              {
                Ok(_) -> content
                Error(_) ->
                  "{\"output\":" <> json.to_string(json.string(content)) <> "}"
              }
              let id_part = case
                find_tool_call_provider_id(preceding_turn, call_id)
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
      build_google_contents_loop(rest, [], list.append(acc, [turn]))
    }
    [message, ..rest] -> {
      use turn <- result.try(single_google_turn(message))
      build_google_contents_loop(rest, [message], list.append(acc, [turn]))
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
    types.AssistantTurnMessage(turn) -> google_assistant_turn(turn)
    types.AssistantToolCalls(calls) -> Ok(google_tool_turn("", calls))
    types.AssistantToolCallsWithText(text, calls) ->
      Ok(google_tool_turn(text, calls))
    types.ToolResultMessage(..) -> Ok("{}")
  }
}

fn google_tool_turn(text: String, calls: List(types.ToolCall)) -> String {
  let parts =
    list.map(calls, fn(call) {
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
        <> replayable_arguments_object(call.arguments_json)
        <> id_part
        <> "}"
      "{\"functionCall\":" <> fc <> thought_signature_part <> "}"
    })
  let text_parts = case text {
    "" -> []
    _ -> ["{\"text\":" <> json.to_string(json.string(text)) <> "}"]
  }
  "{\"role\":\"model\",\"parts\":["
  <> string.join(list.append(text_parts, parts), ",")
  <> "]}"
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
        types.AssistantToolCalls(calls)
        | types.AssistantToolCallsWithText(_, calls)
        | types.AssistantTurnMessage(types.AssistantTurn(calls: calls, ..)) ->
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
        types.AssistantToolCalls(calls)
        | types.AssistantToolCallsWithText(_, calls)
        | types.AssistantTurnMessage(types.AssistantTurn(calls: calls, ..)) ->
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
    types.AssistantTurnMessage(turn) -> {
      use Nil <- result.try(require_canonical_data(turn))
      Ok(anthropic_tool_message(turn.text, turn.calls))
    }
    types.AssistantToolCalls(calls) -> Ok(anthropic_tool_message("", calls))
    types.AssistantToolCallsWithText(text, calls) ->
      Ok(anthropic_tool_message(text, calls))
  }
}

fn anthropic_tool_message(text: String, calls: List(types.ToolCall)) -> String {
  let blocks =
    list.map(calls, fn(call) {
      "{\"type\":\"tool_use\",\"id\":"
      <> json.to_string(json.string(types.call_id_to_string(call.id)))
      <> ",\"name\":"
      <> json.to_string(json.string(types.tool_name_to_string(call.name)))
      <> ",\"input\":"
      <> replayable_arguments_object(call.arguments_json)
      <> "}"
    })
  let text_blocks = case text {
    "" -> []
    _ -> [
      "{\"type\":\"text\",\"text\":" <> json.to_string(json.string(text)) <> "}",
    ]
  }
  "{\"role\":\"assistant\",\"content\":["
  <> string.join(list.append(text_blocks, blocks), ",")
  <> "]}"
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

/// Anthropic `input` and Google `args` must be JSON objects, while a call's
/// arguments are the text the model produced. Object text replays verbatim.
/// Any other text, such as truncated JSON the runtime reported as
/// `InvalidArguments`, replays as `{"unparsed_arguments": text}`, so the
/// provider accepts the turn and the model still sees what it sent. OpenAI
/// carries arguments as a string and needs no such encoding.
fn replayable_arguments_object(raw: String) -> String {
  case json.parse(raw, decode.dict(decode.string, decode.dynamic)) {
    Ok(_) -> raw
    Error(_) ->
      json.to_string(json.object([#("unparsed_arguments", json.string(raw))]))
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
        types.Custom(_) -> []
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
    types.AssistantTurnMessage(turn) ->
      openai_message_items(types.AssistantToolCallsWithText(
        turn.text,
        turn.calls,
      ))
    types.AssistantToolCalls(calls) ->
      list.map(calls, fn(call) {
        json.object([
          #("type", json.string("function_call")),
          #("call_id", json.string(types.call_id_to_string(call.id))),
          #("name", json.string(types.tool_name_to_string(call.name))),
          #("arguments", json.string(call.arguments_json)),
        ])
      })
    types.AssistantToolCallsWithText(text, calls) -> {
      let text_items = case text {
        "" -> []
        _ -> openai_message_items(types.AssistantMessage(text))
      }
      list.append(
        text_items,
        openai_message_items(types.AssistantToolCalls(calls)),
      )
    }
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
) -> Result(#(String, Int, String, tls.TlsMode), types.WireError) {
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
            "https" -> tls.VerifySystem
            _ -> tls.Plaintext
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

/// Built-in profiles enter exactly the same request/reducer boundary as an
/// application adapter. Provider-specific wire rules stay in these closures.
pub fn openai_adapter(
  key: types.ApiKey,
  endpoint: types.Endpoint,
  organization: Option(String),
  project: Option(String),
) -> provider.Adapter {
  let optional_headers =
    list.append(
      case organization {
        Some(value) -> [#("OpenAI-Organization", value)]
        None -> []
      },
      case project {
        Some(value) -> [#("OpenAI-Project", value)]
        None -> []
      },
    )
  provider.adapter(provider.Spec(
    identity: types.OpenAI,
    endpoint: endpoint,
    headers: fn() { request_headers(types.OpenAI, key, optional_headers) },
    encode: fn(request, tools, format) {
      use _ <- result.try(
        list.try_map(request.messages, fn(message) {
          case message {
            types.AssistantTurnMessage(turn) -> require_canonical_data(turn)
            _ -> Ok(Nil)
          }
        }),
      )
      use body <- result.try(encode_openai_request(
        request,
        projected_tool_json(types.OpenAI, tools),
        internal_format(format),
      ))
      Ok(provider.EncodedRequest("/responses", json.to_string(body)))
    },
    project_tool_schema: schema.provider_schema,
    project_output_schema: schema.strict_output_schema,
    new_reducer: openai_reducer,
  ))
}

pub fn anthropic_adapter(
  key: types.ApiKey,
  endpoint: types.Endpoint,
  version: Option(String),
) -> provider.Adapter {
  let optional_headers = case version {
    Some(value) -> [#("anthropic-version", value)]
    None -> []
  }
  provider.adapter(provider.Spec(
    identity: types.Anthropic,
    endpoint: endpoint,
    headers: fn() { request_headers(types.Anthropic, key, optional_headers) },
    encode: fn(request, tools, format) {
      use body <- result.try(encode_anthropic_request(
        request,
        projected_tool_json(types.Anthropic, tools),
        internal_format(format),
      ))
      Ok(provider.EncodedRequest("/messages", body))
    },
    project_tool_schema: schema.provider_schema,
    project_output_schema: schema.strict_output_schema,
    new_reducer: anthropic_reducer,
  ))
}

pub fn google_adapter(
  key: types.ApiKey,
  endpoint: types.Endpoint,
  api_version: Option(String),
) -> provider.Adapter {
  let optional_headers = case api_version {
    Some(value) -> [#("x-goog-api-version", value)]
    None -> []
  }
  provider.adapter(provider.Spec(
    identity: types.Google,
    endpoint: endpoint,
    headers: fn() { request_headers(types.Google, key, optional_headers) },
    encode: fn(request, tools, format) {
      use body <- result.try(encode_google_request(
        request,
        projected_tool_json(types.Google, tools),
        internal_format(format),
      ))
      Ok(provider.EncodedRequest(google_path(request), body))
    },
    project_tool_schema: schema.google_function_parameters_schema,
    project_output_schema: schema.google_strict_output_schema,
    new_reducer: google_reducer,
  ))
}

fn google_path(request: types.Request) -> String {
  "/models/"
  <> types.model_id_to_string(request.model)
  <> ":streamGenerateContent?alt=sse"
}

fn internal_format(
  format: Option(provider.OutputFormat),
) -> Option(StructuredFormat) {
  case format {
    None -> None
    Some(provider.OutputFormat(name, schema_json)) ->
      Some(StructuredFormat(name, schema_json))
  }
}

fn projected_tool_json(
  identity: types.Provider,
  tools: List(provider.ProjectedTool),
) -> List(json.Json) {
  list.map(tools, fn(tool) {
    let provider.ProjectedTool(name, description, schema_json) = tool
    let common = [
      #("name", json.string(types.tool_name_to_string(name))),
      #("description", json.string(description)),
    ]
    case identity {
      types.OpenAI ->
        json.object([
          #("type", json.string("function")),
          ..list.append(common, [
            #("parameters", schema_json),
          ])
        ])
      types.Anthropic ->
        json.object(list.append(common, [#("input_schema", schema_json)]))
      types.Google ->
        json.object(
          list.append(common, [#("parametersJsonSchema", schema_json)]),
        )
      types.Custom(_) -> json.object(common)
    }
  })
}

fn event_for_builtin(event: provider.Event) -> sse.ServerSentEvent {
  sse.ServerSentEvent(event.event, event.data, event.id, event.retry)
}

fn openai_reducer(
  limits: types.Limits,
  tools: List(types.ToolDefinition),
) -> Result(provider.Reducer, types.WireError) {
  use state <- result.try(openai.new_with_tools(limits, tools))
  Ok(provider.reducer(
    state,
    fn(current, event) { openai.step(current, event_for_builtin(event)) },
    fn(current) { map_builtin_terminal(openai.terminal(current)) },
    openai.retry_evidence,
  ))
}

fn anthropic_reducer(
  limits: types.Limits,
  tools: List(types.ToolDefinition),
) -> Result(provider.Reducer, types.WireError) {
  use state <- result.try(anthropic.new_with_tools(limits, tools))
  Ok(provider.reducer(
    state,
    fn(current, event) { anthropic.step(current, event_for_builtin(event)) },
    fn(current) { map_builtin_terminal(anthropic.terminal(current)) },
    anthropic.retry_evidence,
  ))
}

fn google_reducer(
  limits: types.Limits,
  tools: List(types.ToolDefinition),
) -> Result(provider.Reducer, types.WireError) {
  use state <- result.try(google.new_with_tools(limits, tools))
  Ok(provider.reducer(
    state,
    fn(current, event) { google.step(current, event_for_builtin(event)) },
    fn(current) { map_builtin_terminal(google.terminal(current)) },
    google.retry_evidence,
  ))
}

fn map_builtin_terminal(
  terminal: Option(stream_types.TerminalOutcome),
) -> Option(provider.Terminal) {
  case terminal {
    None -> None
    Some(stream_types.StreamFinished(outcome, usage)) ->
      Some(case outcome {
        stream_types.CompletedText(text) -> provider.Text(text, usage)
        // A reducer reports no issues; the runtime admits the calls.
        stream_types.CompletedToolCalls(text, calls, response_id, _) ->
          provider.ToolCalls(text, calls, response_id, None, usage)
        stream_types.CompletedToolCallsWithData(
          text,
          calls,
          response_id,
          data,
          _,
        ) -> provider.ToolCalls(text, calls, response_id, Some(data), usage)
        stream_types.OutputLimited(text, calls) ->
          provider.OutputLimited(text, calls, usage)
        stream_types.Refused(reason) -> provider.Refusal(reason, usage)
      })
    Some(stream_types.StreamFailed(error, retry)) ->
      Some(provider.Failure(error, retry))
    Some(stream_types.StreamCancelledLocally(retry)) ->
      Some(provider.Cancellation(retry))
  }
}

fn require_canonical_data(
  turn: types.AssistantTurn,
) -> Result(Nil, types.WireError) {
  case turn.provider_data {
    None -> Ok(Nil)
    Some(_) ->
      Error(types.PreparationError(
        "This provider does not accept opaque assistant data",
      ))
  }
}

/// Admit only the transcript supplied for this request. No live or retained
/// execution state participates in pairing calls with their results.
fn admit_messages(
  messages: List(types.Message),
  identity: types.Provider,
  limits: types.Limits,
) -> Result(List(types.Message), types.WireError) {
  case messages {
    [] -> Ok([])
    [types.ToolResultMessage(..), ..] ->
      Error(types.PreparationError(
        "Tool result has no preceding assistant calls",
      ))
    [message, ..rest] -> {
      let calls = case message {
        types.AssistantToolCalls(calls)
        | types.AssistantToolCallsWithText(_, calls) -> Some(calls)
        types.AssistantTurnMessage(turn) -> Some(turn.calls)
        _ -> None
      }
      use Nil <- result.try(case message {
        types.AssistantTurnMessage(turn) -> {
          use Nil <- result.try(case turn.provider == identity {
            True -> Ok(Nil)
            False ->
              Error(types.PreparationError(
                "Assistant turn belongs to a different provider",
              ))
          })
          use Nil <- result.try(call_admission.validate_text(limits, turn.text))
          call_admission.validate_metadata(
            limits,
            turn.calls,
            turn.response_id,
            turn.provider_data,
          )
        }
        types.AssistantToolCalls(calls) ->
          call_admission.validate_metadata(limits, calls, None, None)
        types.AssistantToolCallsWithText(text, calls) -> {
          use Nil <- result.try(call_admission.validate_text(limits, text))
          call_admission.validate_metadata(limits, calls, None, None)
        }
        _ -> Ok(Nil)
      })
      case calls {
        None -> {
          use following <- result.try(admit_messages(rest, identity, limits))
          Ok([message, ..following])
        }
        Some(calls) -> {
          // Historical calls need not name tools available in the current request.
          use _ <- result.try(call_admission.admit(
            calls,
            [],
            limits,
            types.ReportInvalidToolCalls,
          ))
          let #(result_messages, remaining) =
            collect_consecutive_tool_results(rest, [])
          let results =
            list.filter_map(result_messages, fn(item) {
              case item {
                types.ToolResultMessage(id, content) ->
                  Ok(types.ToolResult(id, content))
                _ -> Error(Nil)
              }
            })
          use ordered <- result.try(validate_tool_results(
            list.map(calls, fn(call) { call.id }),
            results,
          ))
          use following <- result.try(admit_messages(
            remaining,
            identity,
            limits,
          ))
          Ok([
            message,
            ..list.append(
              list.map(ordered, fn(item) {
                types.ToolResultMessage(item.call_id, item.content)
              }),
              following,
            )
          ])
        }
      }
    }
  }
}

fn google_assistant_turn(
  turn: types.AssistantTurn,
) -> Result(String, types.WireError) {
  use data <- result.try(case turn.provider_data {
    None ->
      Error(types.PreparationError(
        "Google assistant turn is missing provider data",
      ))
    Some(data) -> Ok(data)
  })
  use Nil <- result.try(
    json_bounds.check_depth(data)
    |> result.replace_error(types.PreparationError(
      "Google data nesting exceeds 64",
    )),
  )
  use parts <- result.try(
    json.parse(data, decode.list(decode.string))
    |> result.replace_error(types.PreparationError(
      "Invalid Google assistant data",
    )),
  )
  use _ <- result.try(
    list.try_map(parts, fn(part) {
      use Nil <- result.try(
        json_bounds.check_depth(part)
        |> result.replace_error(types.PreparationError(
          "Google part nesting exceeds 64",
        )),
      )
      json.parse(part, decode.dict(decode.string, decode.dynamic))
      |> result.replace_error(types.PreparationError(
        "Google part is not an object",
      ))
    }),
  )
  let payload =
    "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":["
    <> string.join(parts, ",")
    <> "]}}]}"
  // Request admission already checked caller limits. This pass verifies wire
  // meaning using the same reducer, with bounds derived from the bounded data.
  let bytes = string.byte_size(payload) + 1
  let limits =
    types.Limits(
      ..types.default_limits(),
      active_blocks_limit: bytes,
      text_bytes_per_block_limit: bytes,
      total_text_bytes_limit: bytes,
      argument_bytes_per_call_limit: bytes,
      total_argument_bytes_limit: bytes,
      provider_metadata_bytes_limit: bytes,
    )
  use #(reducer, _) <- result.try(google.step(
    google.new(limits),
    sse.ServerSentEvent(None, payload, None, None),
  ))
  use Nil <- result.try(case google.terminal(reducer) {
    Some(stream_types.StreamFinished(
      stream_types.CompletedToolCallsWithData(text, calls, _, _, _),
      _,
    ))
      if text == turn.text && calls == turn.calls
    -> Ok(Nil)
    _ ->
      Error(types.PreparationError(
        "Google raw parts disagree with assistant text or calls",
      ))
  })
  let signed =
    list.any(parts, fn(part) {
      case
        json.parse(
          part,
          decode.field("thoughtSignature", decode.string, decode.success),
        )
      {
        Ok(_) -> True
        Error(_) -> False
      }
    })
  case signed {
    True ->
      Ok("{\"role\":\"model\",\"parts\":[" <> string.join(parts, ",") <> "]}")
    False -> Ok(google_tool_turn(turn.text, turn.calls))
  }
}
