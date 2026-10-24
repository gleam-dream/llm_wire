//// Pure preparation: admits a request against its adapter and limits and
//// encodes it once. Nothing here performs I/O.

import gleam/bit_array
import gleam/float
import gleam/http
import gleam/http/request as http_request
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order.{Gt, Lt}
import gleam/result
import gleam/string
import json/blueprint/codec
import llm_wire/error.{type PrepareError}
import llm_wire/internal/adapter.{type Adapter}
import llm_wire/internal/limits.{type Limits}
import llm_wire/internal/tool_def.{type Tool}
import llm_wire/limit
import llm_wire/message.{type Message}

/// A provider-bound request whose options, messages and schemas were
/// admitted locally. The body is encoded once and never re-encoded.
pub opaque type PreparedCall {
  PreparedCall(
    adapter: Adapter,
    request: adapter.Request,
    tools: List(Tool),
    host: String,
    port: Int,
    path: String,
    scheme: http.Scheme,
    // A closure, so the credential header never prints with the call.
    headers: fn() -> List(#(String, String)),
    body: String,
  )
}

pub fn provider(prepared: PreparedCall) -> message.Provider {
  adapter.provider(prepared.adapter)
}

pub fn adapter(prepared: PreparedCall) -> Adapter {
  prepared.adapter
}

pub fn tools(prepared: PreparedCall) -> List(Tool) {
  prepared.tools
}

pub fn request(prepared: PreparedCall) -> adapter.Request {
  prepared.request
}

pub fn path(prepared: PreparedCall) -> String {
  prepared.path
}

pub fn scheme(prepared: PreparedCall) -> http.Scheme {
  prepared.scheme
}

pub fn request_json(prepared: PreparedCall) -> String {
  prepared.body
}

/// The admitted HTTP request. Header names are lowercase.
pub fn http_request(prepared: PreparedCall) -> http_request.Request(BitArray) {
  let #(path, query) = case string.split_once(prepared.path, "?") {
    Ok(#(path, query)) -> #(path, Some(query))
    Error(Nil) -> #(prepared.path, None)
  }
  http_request.Request(
    method: http.Post,
    scheme: prepared.scheme,
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

pub fn prepare(
  provider_adapter: Adapter,
  request: adapter.Request,
  tools: List(Tool),
  output: Option(#(String, codec.Schema)),
  limits: Limits,
) -> Result(PreparedCall, PrepareError) {
  use Nil <- result.try(adapter.validate(provider_adapter))
  use Nil <- result.try(limits.validate(limits))
  let model = string.trim(request.model)
  use Nil <- result.try(case model {
    "" -> Error(error.InvalidSetting(error.Model, "the model name is empty"))
    _ -> Ok(Nil)
  })
  let identity = adapter.provider(provider_adapter)
  use messages <- result.try(admit_messages(request.messages, identity, limits))
  let request = adapter.Request(..request, model:, messages:)
  use Nil <- result.try(admit_tool_catalog(tools))
  use projected <- result.try(
    list.try_map(tools, fn(declared) {
      adapter.project_tool_schema(provider_adapter, tool_def.schema(declared))
      |> result.map(adapter.ProjectedTool(
        tool_def.name(declared),
        tool_def.description(declared),
        _,
      ))
      |> result.map_error(error.UnsupportedSchema(
        error.ToolInput(tool_def.name(declared)),
        _,
      ))
    }),
  )
  use format <- result.try(case output {
    None -> Ok(None)
    Some(#(name, schema)) ->
      case string.trim(name) {
        "" ->
          Error(error.InvalidSetting(
            error.OutputName,
            "the output name is empty",
          ))
        trimmed ->
          adapter.project_output_schema(provider_adapter, schema)
          |> result.map(fn(json) { Some(adapter.OutputFormat(trimmed, json)) })
          |> result.map_error(error.UnsupportedSchema(error.Output, _))
      }
  })
  use #(host, port, base_path, scheme) <- result.try(
    parse_endpoint(adapter.endpoint(provider_adapter)),
  )
  use Nil <- result.try(validate_options(request))
  use Nil <- result.try(validate_provider_options(identity, request))
  use encoded <- result.try(adapter.encode(
    provider_adapter,
    request,
    projected,
    format,
  ))
  let provider_headers = adapter.headers(provider_adapter)
  use Nil <- result.try(validate_headers(provider_headers))
  use Nil <- result.try(validate_path(base_path <> encoded.path))
  let headers = list.append(provider_headers, common_headers())
  let body_bytes = string.byte_size(encoded.body)
  case body_bytes > limits.request_bytes_limit {
    True ->
      Error(error.RequestTooLarge(
        limit.RequestBytes,
        limits.request_bytes_limit,
        body_bytes,
      ))
    False ->
      Ok(PreparedCall(
        adapter: provider_adapter,
        request:,
        tools:,
        host:,
        port:,
        path: base_path <> encoded.path,
        scheme:,
        headers: fn() { headers },
        body: encoded.body,
      ))
  }
}

fn admit_tool_catalog(tools: List(Tool)) -> Result(Nil, PrepareError) {
  list.try_fold(tools, [], fn(seen, declared) {
    let name = tool_def.name(declared)
    case list.contains(seen, name) {
      True -> Error(error.InvalidRequest(error.DuplicateToolName(name)))
      False -> Ok([name, ..seen])
    }
  })
  |> result.replace(Nil)
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
) -> Result(Nil, PrepareError) {
  case
    list.find(headers, fn(header) {
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
    Ok(header) -> {
      let name =
        header.0 |> string.replace("\r", "") |> string.replace("\n", "")
      Error(error.InvalidSetting(
        error.Header,
        "header \"" <> name <> "\" is reserved or contains a line break",
      ))
    }
    Error(Nil) -> Ok(Nil)
  }
}

fn validate_path(path: String) -> Result(Nil, PrepareError) {
  case
    string.starts_with(path, "/")
    && !string.contains(path, "\r")
    && !string.contains(path, "\n")
    && !string.contains(path, " ")
  {
    True -> Ok(Nil)
    False ->
      Error(error.InvalidSetting(
        error.Endpoint,
        "the request path is not a valid HTTP path",
      ))
  }
}

fn validate_options(request: adapter.Request) -> Result(Nil, PrepareError) {
  let invalid = fn(problem) { Error(error.InvalidRequest(problem)) }
  use Nil <- result.try(case request.prompt_cache {
    Some(adapter.OpenAiPromptCacheKey(key)) ->
      case string.trim(key) {
        "" -> invalid(error.EmptyPromptCache)
        _ -> Ok(Nil)
      }
    Some(adapter.GoogleCachedContent(name)) ->
      case string.trim(name) {
        "" -> invalid(error.EmptyPromptCache)
        _ -> Ok(Nil)
      }
    None -> Ok(Nil)
  })
  use Nil <- result.try(case request.max_tokens {
    Some(value) if value <= 0 -> invalid(error.MaxTokensNotPositive)
    _ -> Ok(Nil)
  })
  use Nil <- result.try(case request.temperature {
    Some(value) ->
      case in_float_range(value, 0.0, 2.0) {
        True -> Ok(Nil)
        False -> invalid(error.TemperatureOutOfRange)
      }
    None -> Ok(Nil)
  })
  case request.top_p {
    Some(value) ->
      case in_float_range(value, 0.0, 1.0) {
        True -> Ok(Nil)
        False -> invalid(error.TopPOutOfRange)
      }
    None -> Ok(Nil)
  }
}

fn validate_provider_options(
  provider: message.Provider,
  request: adapter.Request,
) -> Result(Nil, PrepareError) {
  let invalid = fn(problem) { Error(error.InvalidRequest(problem)) }
  case provider {
    message.OpenAI -> {
      use Nil <- result.try(case request.prompt_cache {
        None | Some(adapter.OpenAiPromptCacheKey(_)) -> Ok(Nil)
        Some(adapter.GoogleCachedContent(_)) ->
          invalid(error.PromptCacheUnsupported)
      })
      case request.stop_sequences {
        [] -> Ok(Nil)
        _ -> invalid(error.StopSequencesUnsupported)
      }
    }
    message.Google ->
      case request.prompt_cache {
        None | Some(adapter.GoogleCachedContent(_)) ->
          case list.length(request.stop_sequences) > 5 {
            True -> invalid(error.TooManyStopSequences(5))
            False -> Ok(Nil)
          }
        Some(adapter.OpenAiPromptCacheKey(_)) ->
          invalid(error.PromptCacheUnsupported)
      }
    message.Anthropic ->
      case request.prompt_cache {
        None -> Ok(Nil)
        Some(_) -> invalid(error.PromptCacheUnsupported)
      }
    message.Custom(_) -> Ok(Nil)
  }
}

fn in_float_range(value: Float, minimum: Float, maximum: Float) -> Bool {
  float.compare(value, with: minimum) != Lt
  && float.compare(value, with: maximum) != Gt
}

/// Admits `http://` and `https://` endpoints on any host. Whether plaintext
/// may reach a resolved address is decided by HTTP Gun's destination policy
/// at execution, never by matching host names here.
fn parse_endpoint(
  raw: String,
) -> Result(#(String, Int, String, http.Scheme), PrepareError) {
  let raw = string.trim(raw)
  use #(scheme_text, after_scheme) <- result.try(
    case string.split_once(raw, "://") {
      Ok(parts) -> Ok(parts)
      Error(Nil) ->
        invalid_endpoint("the endpoint must start with http:// or https://")
    },
  )
  use #(scheme, default_port) <- result.try(case scheme_text {
    "https" -> Ok(#(http.Https, 443))
    "http" -> Ok(#(http.Http, 80))
    _ -> invalid_endpoint("the endpoint must start with http:// or https://")
  })
  let #(authority, suffix) = case string.split_once(after_scheme, "/") {
    Ok(parts) -> parts
    Error(Nil) -> #(after_scheme, "")
  }
  use Nil <- result.try(
    case
      authority == ""
      || string.contains(authority, "@")
      || string.contains(suffix, "?")
      || string.contains(suffix, "#")
    {
      True -> invalid_endpoint("the endpoint authority or path is invalid")
      False -> Ok(Nil)
    },
  )
  use #(host, port_text) <- result.try(split_authority(authority))
  use port <- result.try(case port_text {
    None -> Ok(default_port)
    Some(text) ->
      case int.parse(text) {
        Ok(port) if port >= 1 && port <= 65_535 -> Ok(port)
        _ -> invalid_endpoint("the endpoint port is invalid")
      }
  })
  use Nil <- result.try(
    case
      host == ""
      || string.contains(host, "/")
      || string.contains(host, " ")
      || string.contains(host, "\r")
      || string.contains(host, "\n")
    {
      True -> invalid_endpoint("the endpoint host is invalid")
      False -> Ok(Nil)
    },
  )
  let base_path = case suffix {
    "" -> ""
    value -> "/" <> trim_trailing_slashes(value)
  }
  Ok(#(host, port, base_path, scheme))
}

/// Splits `host`, `host:port`, `[v6]` and `[v6]:port`.
fn split_authority(
  authority: String,
) -> Result(#(String, Option(String)), PrepareError) {
  let invalid =
    Error(error.InvalidSetting(
      error.Endpoint,
      "the endpoint authority is invalid",
    ))
  case string.starts_with(authority, "[") {
    True ->
      case string.split_once(string.drop_start(authority, 1), "]") {
        Ok(#(host, "")) -> Ok(#(host, None))
        Ok(#(host, rest)) ->
          case string.starts_with(rest, ":") {
            True -> Ok(#(host, Some(string.drop_start(rest, 1))))
            False -> invalid
          }
        Error(Nil) -> invalid
      }
    False ->
      case string.split_once(authority, ":") {
        Ok(#(host, port)) -> Ok(#(host, Some(port)))
        Error(Nil) -> Ok(#(authority, None))
      }
  }
}

fn invalid_endpoint(reason: String) -> Result(a, PrepareError) {
  Error(error.InvalidSetting(error.Endpoint, reason))
}

fn trim_trailing_slashes(path: String) -> String {
  case string.ends_with(path, "/") {
    True -> trim_trailing_slashes(string.drop_end(path, 1))
    False -> path
  }
}

/// Admit only the transcript supplied for this request. No retained
/// execution state participates in pairing calls with their results.
fn admit_messages(
  messages: List(Message),
  identity: message.Provider,
  limits: Limits,
) -> Result(List(Message), PrepareError) {
  case messages {
    [] -> Ok([])
    [message.ToolResult(call_id, _), ..] ->
      Error(error.ToolResultMismatch(call_id, error.NoPrecedingCalls))
    [message.Assistant(turn) as msg, ..rest] -> {
      use Nil <- result.try(admit_turn(turn, identity, limits))
      case turn.calls {
        [] -> {
          use following <- result.try(admit_messages(rest, identity, limits))
          Ok([msg, ..following])
        }
        calls -> {
          let #(results, remaining) = consecutive_results(rest, [])
          use ordered <- result.try(match_results(calls, results))
          use following <- result.try(admit_messages(
            remaining,
            identity,
            limits,
          ))
          Ok([msg, ..list.append(ordered, following)])
        }
      }
    }
    [msg, ..rest] -> {
      use following <- result.try(admit_messages(rest, identity, limits))
      Ok([msg, ..following])
    }
  }
}

fn admit_turn(
  turn: message.AssistantTurn,
  identity: message.Provider,
  limits: Limits,
) -> Result(Nil, PrepareError) {
  use Nil <- result.try(case turn.provider {
    Some(provider) if provider != identity ->
      Error(error.InvalidRequest(error.TurnFromOtherProvider))
    _ -> Ok(Nil)
  })
  let text_bytes = string.byte_size(turn.text)
  use Nil <- result.try(case text_bytes > limits.total_text_bytes_limit {
    True -> too_large(limits, limit.TotalTextBytes, text_bytes)
    False -> Ok(Nil)
  })
  let metadata =
    list.fold(
      turn.calls,
      option_bytes(turn.response_id) + option_bytes(turn.provider_data),
      fn(total, call) {
        total
        + string.byte_size(call.id)
        + string.byte_size(call.name)
        + option_bytes(call.provider_id)
        + option_bytes(call.provider_state)
      },
    )
  use Nil <- result.try(case metadata > limits.provider_metadata_bytes_limit {
    True -> too_large(limits, limit.ProviderMetadataBytes, metadata)
    False -> Ok(Nil)
  })
  let count = list.length(turn.calls)
  use Nil <- result.try(case count > limits.active_blocks_limit {
    True -> too_large(limits, limit.ActiveBlocks, count)
    False -> Ok(Nil)
  })
  use _ <- result.try(
    list.try_fold(turn.calls, #([], 0), fn(acc, call) {
      let #(seen, total) = acc
      let bytes = string.byte_size(call.arguments_json)
      use Nil <- result.try(
        case string.trim(call.id) == "" || list.contains(seen, call.id) {
          True -> Error(error.InvalidRequest(error.InvalidCallId(call.id)))
          False -> Ok(Nil)
        },
      )
      use Nil <- result.try(case tool_def.check_name(call.name) {
        Ok(Nil) -> Ok(Nil)
        Error(_) ->
          Error(error.InvalidRequest(error.InvalidToolName(call.name)))
      })
      use Nil <- result.try(case bytes > limits.argument_bytes_per_call_limit {
        True -> too_large(limits, limit.ArgumentBytesPerCall, bytes)
        False -> Ok(Nil)
      })
      case total + bytes > limits.total_argument_bytes_limit {
        True -> too_large(limits, limit.TotalArgumentBytes, total + bytes)
        False -> Ok(#([call.id, ..seen], total + bytes))
      }
    }),
  )
  Ok(Nil)
}

fn too_large(
  limits: Limits,
  which: limit.Limit,
  measured: Int,
) -> Result(a, PrepareError) {
  Error(error.RequestTooLarge(which, limits.get(limits, which), measured))
}

fn option_bytes(value: Option(String)) -> Int {
  case value {
    Some(text) -> string.byte_size(text)
    None -> 0
  }
}

fn consecutive_results(
  messages: List(Message),
  acc: List(#(String, String)),
) -> #(List(#(String, String)), List(Message)) {
  case messages {
    [message.ToolResult(call_id, content), ..rest] ->
      consecutive_results(rest, [#(call_id, content), ..acc])
    _ -> #(list.reverse(acc), messages)
  }
}

/// One result per call, returned in call order.
fn match_results(
  calls: List(message.ToolCall),
  results: List(#(String, String)),
) -> Result(List(Message), PrepareError) {
  let ids = list.map(calls, fn(call) { call.id })
  use _ <- result.try(
    list.try_fold(results, [], fn(seen, found) {
      let #(id, _) = found
      case list.contains(ids, id), list.contains(seen, id) {
        False, _ -> Error(error.ToolResultMismatch(id, error.UnknownCall))
        True, True -> Error(error.ToolResultMismatch(id, error.DuplicateResult))
        True, False -> Ok([id, ..seen])
      }
    }),
  )
  list.try_map(ids, fn(id) {
    case list.key_find(results, id) {
      Ok(content) -> Ok(message.ToolResult(id, content))
      Error(Nil) -> Error(error.ToolResultMismatch(id, error.MissingResult))
    }
  })
}
