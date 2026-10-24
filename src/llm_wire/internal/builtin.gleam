import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import llm_wire/error
import llm_wire/internal/adapter
import llm_wire/internal/anthropic
import llm_wire/internal/google
import llm_wire/internal/json_bounds
import llm_wire/internal/limits
import llm_wire/internal/openai
import llm_wire/internal/schema
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/message

fn encode_openai_request(
  request: adapter.Request,
  tools: List(json.Json),
  structured_format: Option(adapter.OutputFormat),
) -> Result(json.Json, error.PrepareError) {
  let empty: Result(List(json.Json), error.PrepareError) = Ok([])
  use input_items <- result.try(
    list.fold(request.messages, empty, fn(acc, msg) {
      use prior <- result.try(acc)
      Ok(list.append(prior, openai_message_items(msg)))
    }),
  )
  let base = [
    #("model", json.string(request.model)),
    #("input", json.array(input_items, fn(value) { value })),
    #("stream", json.bool(True)),
  ]
  let options = request_option_fields(request, message.OpenAI)
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
  request: adapter.Request,
  tools: List(json.Json),
  structured_format: Option(adapter.OutputFormat),
) -> Result(String, error.PrepareError) {
  let system =
    list.filter_map(request.messages, fn(msg) {
      case msg {
        message.System(content) -> Ok(content)
        _ -> Error(Nil)
      }
    })
    |> string.join("\n")
  let empty: Result(List(String), error.PrepareError) = Ok([])
  use messages <- result.try(
    list.fold(request.messages, empty, fn(acc, msg) {
      use encoded <- result.try(acc)
      case msg {
        message.System(_) -> Ok(encoded)
        _ -> {
          use message_json <- result.try(anthropic_message_json(msg))
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
    #("model", json.to_string(json.string(request.model))),
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
    list.map(request_option_fields(request, message.Anthropic), fn(field) {
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
  request: adapter.Request,
  tools: List(json.Json),
  structured_format: Option(adapter.OutputFormat),
) -> Result(String, error.PrepareError) {
  let system_parts =
    list.filter_map(request.messages, fn(msg) {
      case msg {
        message.System(content) ->
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
    Some(adapter.GoogleCachedContent(name)) -> [
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
  request: adapter.Request,
  structured_format: Option(adapter.OutputFormat),
) -> Option(json.Json) {
  let option_fields = request_option_fields(request, message.Google)
  let format_fields = case structured_format {
    Some(adapter.OutputFormat(_, schema_json)) -> [
      #("responseMimeType", json.string("application/json")),
      #("responseJsonSchema", schema_json),
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
  messages: List(message.Message),
) -> Result(List(String), error.PrepareError) {
  let non_system =
    list.filter(messages, fn(m) {
      case m {
        message.System(_) -> False
        _ -> True
      }
    })
  build_google_contents_loop(non_system, [], [])
}

fn build_google_contents_loop(
  remaining: List(message.Message),
  preceding_turn: List(message.Message),
  acc: List(String),
) -> Result(List(String), error.PrepareError) {
  case remaining {
    [] -> Ok(acc)
    [message.ToolResult(..), ..] -> {
      let #(tool_results, rest) =
        collect_consecutive_tool_results(remaining, [])
      use response_parts <- result.try(
        list.fold(tool_results, Ok([]), fn(p_acc, tr) {
          use parts_so_far <- result.try(p_acc)
          case tr {
            message.ToolResult(call_id, content) -> {
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
    [msg, ..rest] -> {
      use turn <- result.try(single_google_turn(msg))
      build_google_contents_loop(rest, [msg], list.append(acc, [turn]))
    }
  }
}

fn collect_consecutive_tool_results(
  messages: List(message.Message),
  acc: List(message.Message),
) -> #(List(message.Message), List(message.Message)) {
  case messages {
    [message.ToolResult(..) as tr, ..rest] ->
      collect_consecutive_tool_results(rest, list.append(acc, [tr]))
    _ -> #(acc, messages)
  }
}

fn single_google_turn(
  msg: message.Message,
) -> Result(String, error.PrepareError) {
  case msg {
    message.System(_) -> Ok("{}")
    message.User(content) ->
      Ok(
        "{\"role\":\"user\",\"parts\":[{\"text\":"
        <> json.to_string(json.string(content))
        <> "}]}",
      )
    message.UserParts(parts) -> {
      use encoded <- result.try(google_content_parts(parts))
      Ok("{\"role\":\"user\",\"parts\":[" <> string.join(encoded, ",") <> "]}")
    }
    message.Assistant(turn) -> google_assistant_turn(turn)
    message.AssistantParts(parts) -> {
      use encoded <- result.try(google_content_parts(parts))
      Ok("{\"role\":\"model\",\"parts\":[" <> string.join(encoded, ",") <> "]}")
    }
    message.ToolResult(..) -> Ok("{}")
  }
}

fn google_tool_turn(text: String, calls: List(message.ToolCall)) -> String {
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
        <> json.to_string(json.string(call.name))
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
  parts: List(message.Content),
) -> Result(List(String), error.PrepareError) {
  list.fold(parts, Ok([]), fn(acc, part) {
    use prior <- result.try(acc)
    case part {
      message.TextPart(text) ->
        Ok(
          list.append(prior, [
            "{\"text\":" <> json.to_string(json.string(text)) <> "}",
          ]),
        )
      message.InlineImagePart(mime_type, base64_data) ->
        Ok(
          list.append(prior, [
            "{\"inlineData\":{\"mimeType\":"
            <> json.to_string(json.string(mime_type))
            <> ",\"data\":"
            <> json.to_string(json.string(base64_data))
            <> "}}",
          ]),
        )
      message.ImageUrlPart(_) ->
        Error(error.InvalidRequest(error.ImageUrlUnsupported))
    }
  })
}

fn find_tool_call_name(
  messages: List(message.Message),
  call_id: String,
) -> String {
  let found =
    list.find_map(messages, fn(msg) {
      case msg {
        message.Assistant(message.AssistantTurn(calls:, ..)) ->
          case list.find(calls, fn(c) { c.id == call_id }) {
            Ok(c) -> Ok(c.name)
            Error(Nil) -> Error(Nil)
          }
        _ -> Error(Nil)
      }
    })
  case found {
    Ok(name) -> name
    Error(Nil) -> call_id
  }
}

fn find_tool_call_provider_id(
  messages: List(message.Message),
  call_id: String,
) -> Option(String) {
  let found =
    list.find_map(messages, fn(msg) {
      case msg {
        message.Assistant(message.AssistantTurn(calls:, ..)) ->
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
  msg: message.Message,
) -> Result(String, error.PrepareError) {
  case msg {
    // System messages are lifted into the top-level system field by the
    // request encoder, but keeping this function total avoids a partial wire
    // conversion if the fold changes later.
    message.System(_) -> Ok("{}")
    message.User(content) ->
      Ok(
        json.to_string(
          json.object([
            #("role", json.string("user")),
            #("content", json.string(content)),
          ]),
        ),
      )
    message.UserParts(parts) -> {
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
    message.Assistant(turn) -> {
      use Nil <- result.try(require_canonical_data(turn))
      case turn.calls {
        [] ->
          Ok(
            json.to_string(
              json.object([
                #("role", json.string("assistant")),
                #("content", json.string(turn.text)),
              ]),
            ),
          )
        calls -> Ok(anthropic_tool_message(turn.text, calls))
      }
    }
    message.AssistantParts(parts) -> {
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
    message.ToolResult(call_id, content) ->
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
                    #("tool_use_id", json.string(call_id)),
                    #("content", json.string(content)),
                  ]),
                ],
                fn(value) { value },
              ),
            ),
          ]),
        ),
      )
  }
}

fn anthropic_tool_message(
  text: String,
  calls: List(message.ToolCall),
) -> String {
  let blocks =
    list.map(calls, fn(call) {
      "{\"type\":\"tool_use\",\"id\":"
      <> json.to_string(json.string(call.id))
      <> ",\"name\":"
      <> json.to_string(json.string(call.name))
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
  parts: List(message.Content),
) -> Result(json.Json, error.PrepareError) {
  let empty: Result(List(json.Json), error.PrepareError) = Ok([])
  use encoded <- result.try(
    list.fold(parts, empty, fn(acc, part) {
      use prior <- result.try(acc)
      case part {
        message.TextPart(text) ->
          Ok(
            list.append(prior, [
              json.object([
                #("type", json.string("text")),
                #("text", json.string(text)),
              ]),
            ]),
          )
        message.InlineImagePart(mime_type, base64_data) ->
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
        message.ImageUrlPart(_) ->
          Error(error.InvalidRequest(error.ImageUrlUnsupported))
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
  structured_format: Option(adapter.OutputFormat),
) -> List(#(String, json.Json)) {
  case structured_format {
    None -> []
    Some(adapter.OutputFormat(name, schema_json)) -> [
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
  structured_format: Option(adapter.OutputFormat),
) -> List(#(String, json.Json)) {
  case structured_format {
    None -> []
    Some(adapter.OutputFormat(_, schema_json)) -> [
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
  request: adapter.Request,
  provider: message.Provider,
) -> List(#(String, json.Json)) {
  let max_tokens = case request.max_tokens {
    Some(value) ->
      case provider {
        message.OpenAI -> [#("max_output_tokens", json.int(value))]
        message.Anthropic -> []
        message.Google -> [#("maxOutputTokens", json.int(value))]
        message.Custom(_) -> []
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
        message.Google -> [#("topP", json.float(value))]
        _ -> [#("top_p", json.float(value))]
      }
    None -> []
  }
  let stop = case request.stop_sequences, provider {
    [], _ -> []
    values, message.Anthropic -> [
      #("stop_sequences", json.array(values, json.string)),
    ]
    values, message.Google -> [
      #("stopSequences", json.array(values, json.string)),
    ]
    _, _ -> []
  }
  let cache = case request.prompt_cache, provider {
    Some(adapter.OpenAiPromptCacheKey(key)), message.OpenAI -> [
      #("prompt_cache_key", json.string(key)),
    ]
    _, _ -> []
  }
  list.append(
    max_tokens,
    list.append(temperature, list.append(top_p, list.append(stop, cache))),
  )
}

fn openai_message_items(msg: message.Message) -> List(json.Json) {
  case msg {
    message.System(content) -> [
      json.object([
        #("role", json.string("system")),
        #("content", json.string(content)),
      ]),
    ]
    message.User(content) -> [
      json.object([
        #("role", json.string("user")),
        #("content", json.string(content)),
      ]),
    ]
    message.UserParts(parts) -> [
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
    message.AssistantParts(parts) -> [
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
    message.Assistant(turn) -> {
      let text_items = case turn.text, turn.calls {
        "", [_, ..] -> []
        text, _ -> [
          json.object([
            #("role", json.string("assistant")),
            #("content", json.string(text)),
          ]),
        ]
      }
      list.append(
        text_items,
        list.map(turn.calls, fn(call) {
          json.object([
            #("type", json.string("function_call")),
            #("call_id", json.string(call.id)),
            #("name", json.string(call.name)),
            #("arguments", json.string(call.arguments_json)),
          ])
        }),
      )
    }
    message.ToolResult(call_id, content) -> [
      json.object([
        #("type", json.string("function_call_output")),
        #("call_id", json.string(call_id)),
        #("output", json.string(content)),
      ]),
    ]
  }
}

fn openai_content_parts(
  parts: List(message.Content),
  text_type: String,
) -> List(json.Json) {
  list.map(parts, fn(part) {
    case part {
      message.TextPart(text) ->
        json.object([
          #("type", json.string(text_type)),
          #("text", json.string(text)),
        ])
      message.ImageUrlPart(url) ->
        json.object([
          #("type", json.string("input_image")),
          #("image_url", json.string(url)),
        ])
      message.InlineImagePart(mime_type, base64_data) ->
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

/// Built-in profiles enter exactly the same request/reducer boundary as an
/// application adapter. Provider-specific wire rules stay in these closures.
/// The key is read only inside the headers closure, so it never prints.
pub fn openai_adapter(
  key: fn() -> String,
  organization: Option(String),
  project: Option(String),
) -> adapter.Adapter {
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
  adapter.new(
    provider: message.OpenAI,
    endpoint: "https://api.openai.com/v1",
    headers: fn() {
      [#("Authorization", "Bearer " <> key()), ..optional_headers]
    },
    validate: fn() { require_key(key) },
    encode: fn(request, tools, format) {
      use _ <- result.try(
        list.try_map(request.messages, fn(msg) {
          case msg {
            message.Assistant(turn) -> require_canonical_data(turn)
            _ -> Ok(Nil)
          }
        }),
      )
      use body <- result.try(encode_openai_request(
        request,
        projected_tool_json(message.OpenAI, tools),
        format,
      ))
      Ok(adapter.Encoded("/responses", json.to_string(body)))
    },
    project_tool_schema: schema.provider_schema,
    project_output_schema: schema.strict_output_schema,
    new_reducer: openai_reducer,
  )
}

pub fn anthropic_adapter(
  key: fn() -> String,
  version: Option(String),
) -> adapter.Adapter {
  let version_header = case version {
    Some(value) -> #("anthropic-version", value)
    None -> #("anthropic-version", "2023-06-01")
  }
  adapter.new(
    provider: message.Anthropic,
    endpoint: "https://api.anthropic.com/v1",
    headers: fn() { [#("x-api-key", key()), version_header] },
    validate: fn() { require_key(key) },
    encode: fn(request, tools, format) {
      use body <- result.try(encode_anthropic_request(
        request,
        projected_tool_json(message.Anthropic, tools),
        format,
      ))
      Ok(adapter.Encoded("/messages", body))
    },
    project_tool_schema: schema.provider_schema,
    project_output_schema: schema.strict_output_schema,
    new_reducer: anthropic_reducer,
  )
}

pub fn google_adapter(
  key: fn() -> String,
  api_version: Option(String),
) -> adapter.Adapter {
  let optional_headers = case api_version {
    Some(value) -> [#("x-goog-api-version", value)]
    None -> []
  }
  adapter.new(
    provider: message.Google,
    endpoint: "https://generativelanguage.googleapis.com/v1beta",
    headers: fn() { [#("x-goog-api-key", key()), ..optional_headers] },
    validate: fn() { require_key(key) },
    encode: fn(request, tools, format) {
      use body <- result.try(encode_google_request(
        request,
        projected_tool_json(message.Google, tools),
        format,
      ))
      Ok(adapter.Encoded(google_path(request), body))
    },
    project_tool_schema: schema.google_function_parameters_schema,
    project_output_schema: schema.google_strict_output_schema,
    new_reducer: google_reducer,
  )
}

fn require_key(key: fn() -> String) -> Result(Nil, error.PrepareError) {
  case string.trim(key()) {
    "" -> Error(error.InvalidSetting(error.ApiKey, "the API key is empty"))
    _ -> Ok(Nil)
  }
}

fn google_path(request: adapter.Request) -> String {
  "/models/" <> request.model <> ":streamGenerateContent?alt=sse"
}

fn projected_tool_json(
  identity: message.Provider,
  tools: List(adapter.ProjectedTool),
) -> List(json.Json) {
  list.map(tools, fn(tool) {
    let common = [
      #("name", json.string(tool.name)),
      #("description", json.string(tool.description)),
    ]
    case identity {
      message.OpenAI ->
        json.object([
          #("type", json.string("function")),
          ..list.append(common, [#("parameters", tool.schema)])
        ])
      message.Anthropic ->
        json.object(list.append(common, [#("input_schema", tool.schema)]))
      message.Google ->
        json.object(
          list.append(common, [#("parametersJsonSchema", tool.schema)]),
        )
      message.Custom(_) -> json.object(common)
    }
  })
}

fn openai_reducer(limits: limits.Limits) -> adapter.Reducer {
  adapter.reducer(openai.new(limits), openai.step, fn(current) {
    map_builtin_terminal(openai.terminal(current))
  })
}

fn anthropic_reducer(limits: limits.Limits) -> adapter.Reducer {
  adapter.reducer(anthropic.new(limits), anthropic.step, fn(current) {
    map_builtin_terminal(anthropic.terminal(current))
  })
}

fn google_reducer(limits: limits.Limits) -> adapter.Reducer {
  adapter.reducer(google.new(limits), google.step, fn(current) {
    map_builtin_terminal(google.terminal(current))
  })
}

fn map_builtin_terminal(
  terminal: Option(stream_types.TerminalOutcome),
) -> Option(adapter.Terminal) {
  case terminal {
    None -> None
    Some(stream_types.StreamFinished(outcome, usage)) ->
      Some(case outcome {
        stream_types.CompletedText(text) -> adapter.Text(text, usage)
        // A reducer reports no issues; the runtime admits the calls.
        stream_types.CompletedToolCalls(text, calls, response_id, _) ->
          adapter.ToolCalls(text, calls, response_id, None, usage)
        stream_types.CompletedToolCallsWithData(
          text,
          calls,
          response_id,
          data,
          _,
        ) -> adapter.ToolCalls(text, calls, response_id, Some(data), usage)
        stream_types.OutputLimited(text, calls) ->
          adapter.OutputLimited(text, calls, usage)
        stream_types.Refused(reason) -> adapter.Refusal(reason, usage)
      })
    Some(stream_types.StreamFailed(failure, _)) ->
      Some(adapter.Failed(failure, None))
    Some(stream_types.StreamCancelledLocally(_)) ->
      Some(adapter.Failed(error.Cancelled, None))
  }
}

fn require_canonical_data(
  turn: message.AssistantTurn,
) -> Result(Nil, error.PrepareError) {
  case turn.provider_data {
    None -> Ok(Nil)
    Some(_) ->
      Error(invalid_data("this provider accepts no opaque assistant data"))
  }
}

fn invalid_data(reason: String) -> error.PrepareError {
  error.InvalidRequest(error.InvalidProviderData(reason))
}

/// A Google turn with signed provider data replays its raw parts after the
/// reducer confirms they carry exactly the turn's text and calls. A turn
/// without data, such as one the application wrote, is encoded from its
/// text and calls.
fn google_assistant_turn(
  turn: message.AssistantTurn,
) -> Result(String, error.PrepareError) {
  case turn.provider_data, turn.provider, turn.calls {
    None, Some(message.Google), [_, ..] ->
      Error(invalid_data("a Google turn with calls needs its provider data"))
    None, _, [] ->
      Ok(
        "{\"role\":\"model\",\"parts\":[{\"text\":"
        <> json.to_string(json.string(turn.text))
        <> "}]}",
      )
    None, _, calls -> Ok(google_tool_turn(turn.text, calls))
    Some(data), _, _ -> google_signed_turn(turn, data)
  }
}

fn google_signed_turn(
  turn: message.AssistantTurn,
  data: String,
) -> Result(String, error.PrepareError) {
  use Nil <- result.try(
    json_bounds.check_depth(data)
    |> result.replace_error(invalid_data("Google data nesting exceeds 64")),
  )
  use parts <- result.try(
    json.parse(data, decode.list(decode.string))
    |> result.replace_error(invalid_data("Google data is not a list of parts")),
  )
  use _ <- result.try(
    list.try_map(parts, fn(part) {
      use Nil <- result.try(
        json_bounds.check_depth(part)
        |> result.replace_error(invalid_data("Google part nesting exceeds 64")),
      )
      json.parse(part, decode.dict(decode.string, decode.dynamic))
      |> result.replace_error(invalid_data("a Google part is not an object"))
    }),
  )
  let payload =
    "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":["
    <> string.join(parts, ",")
    <> "]}}]}"
  // Request admission already checked caller limits. This pass verifies wire
  // meaning using the same reducer, with bounds derived from the bounded data.
  let bytes = string.byte_size(payload) + 1
  let bounds =
    limits.Limits(
      ..limits.default(),
      active_blocks_limit: bytes,
      text_bytes_per_block_limit: bytes,
      total_text_bytes_limit: bytes,
      argument_bytes_per_call_limit: bytes,
      total_argument_bytes_limit: bytes,
      provider_metadata_bytes_limit: bytes,
    )
  let verified = case
    google.step(
      google.new(bounds),
      sse.ServerSentEvent(None, payload, None, None),
    )
  {
    Ok(#(reducer, _)) ->
      case google.terminal(reducer) {
        Some(stream_types.StreamFinished(
          stream_types.CompletedToolCallsWithData(text, calls, _, _, _),
          _,
        )) -> text == turn.text && calls == turn.calls
        _ -> False
      }
    Error(_) -> False
  }
  use Nil <- result.try(case verified {
    True -> Ok(Nil)
    False ->
      Error(invalid_data(
        "Google raw parts disagree with the turn's text or calls",
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
