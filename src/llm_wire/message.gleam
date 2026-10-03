//// The values a conversation is made of: messages, assistant turns, tool
//// calls, streamed progress and token usage, with JSON codecs for storing
//// them.
////
//// The caller owns the conversation. Build the next request from the
//// messages you keep, appending each assistant turn and its tool results:
////
//// ```gleam
//// import llm_wire
//// import llm_wire/message
////
//// case llm_wire.run(client, prepared) {
////   Ok(llm_wire.NeedsTools(turn:, ..)) -> {
////     let results =
////       list.map(turn.calls, fn(call) { llm_wire.tool_result(call, "42") })
////     [message.Assistant(turn), ..results]
////   }
////   _ -> []
//// }
//// ```
////
//// `to_json` and `decoder` store a message; `turn_to_json` and
//// `turn_decoder` store an assistant turn with its provider data, which a
//// later request must replay unchanged. A store that keeps a turn's text and
//// calls apart from the rest uses `turn_replay_to_json` and
//// `turn_replay_decoder` for the provider-owned part; it is the format
//// Fabric stores as `llm_wire.turn.v1`.
////
//// Records here are returned by the library; read their fields by label.
//// `Message`, `Content` and `Progress` may gain variants in a minor release,
//// so match them with a `_` arm.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}

/// The provider a turn came from, or a custom adapter's name.
pub type Provider {
  OpenAI
  Anthropic
  Google
  Custom(name: String)
}

/// One part of a multimodal message.
pub type Content {
  TextPart(text: String)
  /// A remote image. OpenAI admits it; Anthropic and Google refuse it during
  /// preparation.
  ImageUrlPart(url: String)
  InlineImagePart(mime_type: String, base64_data: String)
}

/// A tool call the model made. `arguments_json` is the argument text exactly
/// as the model produced it. `provider_id` and `provider_state` carry
/// provider replay data, such as Gemini's call id and thought signature.
pub type ToolCall {
  ToolCall(
    id: String,
    name: String,
    arguments_json: String,
    provider_id: Option(String),
    provider_state: Option(String),
  )
}

/// One assistant response. `provider` is `None` for a turn the application
/// wrote itself. `provider_data` is opaque replay data that a later request
/// to the same provider must carry unchanged, such as Gemini's signed parts.
pub type AssistantTurn {
  AssistantTurn(
    provider: Option(Provider),
    text: String,
    calls: List(ToolCall),
    response_id: Option(String),
    provider_data: Option(String),
  )
}

/// One message of a conversation.
pub type Message {
  System(text: String)
  User(text: String)
  /// A user message made of several parts, such as text and an image.
  UserParts(parts: List(Content))
  /// An assistant turn: a provider response, or text and calls the
  /// application wrote.
  Assistant(turn: AssistantTurn)
  /// An application-written assistant message made of several parts.
  AssistantParts(parts: List(Content))
  /// The result of the call with `call_id`. Results follow the assistant
  /// turn that made the calls, one per call.
  ToolResult(call_id: String, content: String)
}

/// Token counts a provider reported.
pub type Usage {
  Usage(input_tokens: Int, output_tokens: Int, total_tokens: Int)
}

/// One piece of a streamed response.
pub type Progress {
  TextDelta(block_id: String, text: String)
  RefusalDelta(block_id: String, text: String)
  ReasoningDelta(block_id: String, text: String)
  /// Argument text of a tool call still being generated.
  ToolArgumentsDelta(call_id: String, text: String)
  UsageUpdate(usage: Usage)
  /// A provider event LLM Wire does not interpret, by name.
  ProviderExtension(provider: String, event_name: String)
}

/// A tool call without provider replay data, for application-written turns.
pub fn tool_call(id: String, name: String, arguments_json: String) -> ToolCall {
  ToolCall(id:, name:, arguments_json:, provider_id: None, provider_state: None)
}

/// A provider's stable name: `"openai"`, `"anthropic"`, `"google"`, or the
/// custom adapter's name.
pub fn provider_name(provider: Provider) -> String {
  case provider {
    OpenAI -> "openai"
    Anthropic -> "anthropic"
    Google -> "google"
    Custom(name) -> name
  }
}

// --- codecs ------------------------------------------------------------------

const message_format = "llm_wire.message.v1"

const turn_format = "llm_wire.turn.v1"

/// Encode a message as JSON tagged `"format": "llm_wire.message.v1"`.
pub fn to_json(message: Message) -> json.Json {
  let fields = case message {
    System(text) -> [
      #("role", json.string("system")),
      #("text", json.string(text)),
    ]
    User(text) -> [#("role", json.string("user")), #("text", json.string(text))]
    UserParts(parts) -> [
      #("role", json.string("user")),
      #("parts", json.array(parts, content_to_json)),
    ]
    Assistant(turn) -> [
      #("role", json.string("assistant")),
      #("turn", turn_to_json(turn)),
    ]
    AssistantParts(parts) -> [
      #("role", json.string("assistant")),
      #("parts", json.array(parts, content_to_json)),
    ]
    ToolResult(call_id, content) -> [
      #("role", json.string("tool")),
      #("call_id", json.string(call_id)),
      #("content", json.string(content)),
    ]
  }
  json.object([#("format", json.string(message_format)), ..fields])
}

/// Decode a message written by `to_json`. A value with a different
/// `format` tag fails; a value without one is read as version 1.
pub fn decoder() -> decode.Decoder(Message) {
  use Nil <- decode.then(format_decoder(message_format))
  use role <- decode.field("role", decode.string)
  case role {
    "system" ->
      decode.field("text", decode.string, fn(t) { decode.success(System(t)) })
    "tool" -> {
      use call_id <- decode.field("call_id", decode.string)
      use content <- decode.field("content", decode.string)
      decode.success(ToolResult(call_id, content))
    }
    "user" -> {
      use text <- decode.optional_field(
        "text",
        None,
        decode.optional(decode.string),
      )
      case text {
        Some(text) -> decode.success(User(text))
        None ->
          decode.field("parts", decode.list(content_decoder()), fn(parts) {
            decode.success(UserParts(parts))
          })
      }
    }
    "assistant" -> {
      use turn <- decode.optional_field(
        "turn",
        None,
        decode.optional(turn_decoder()),
      )
      case turn {
        Some(turn) -> decode.success(Assistant(turn))
        None ->
          decode.field("parts", decode.list(content_decoder()), fn(parts) {
            decode.success(AssistantParts(parts))
          })
      }
    }
    _ -> decode.failure(System(""), "a message role")
  }
}

/// Encode an assistant turn, provider data included, tagged
/// `"format": "llm_wire.turn.v1"`. Its fields are those of
/// `turn_replay_to_json` plus `text` and `calls`.
pub fn turn_to_json(turn: AssistantTurn) -> json.Json {
  json.object([
    #("format", json.string(turn_format)),
    #("provider", json.nullable(turn.provider, provider_to_json)),
    #("text", json.string(turn.text)),
    #("calls", json.array(turn.calls, call_to_json)),
    #("response_id", json.nullable(turn.response_id, json.string)),
    #("provider_data", json.nullable(turn.provider_data, json.string)),
  ])
}

/// Decode a turn written by `turn_to_json`.
pub fn turn_decoder() -> decode.Decoder(AssistantTurn) {
  use Nil <- decode.then(format_decoder(turn_format))
  use text <- decode.field("text", decode.string)
  use calls <- decode.field("calls", decode.list(call_decoder()))
  replay_fields(text, calls)
}

/// Encode only the provider-owned part of a turn: `provider`,
/// `response_id` and `provider_data`. The caller stores the turn's text and
/// calls itself. This is exactly the data Fabric stores under the
/// `llm_wire.turn.v1` tag, without its former `issues` list.
pub fn turn_replay_to_json(turn: AssistantTurn) -> json.Json {
  json.object([
    #("provider", json.nullable(turn.provider, provider_to_json)),
    #("response_id", json.nullable(turn.response_id, json.string)),
    #("provider_data", json.nullable(turn.provider_data, json.string)),
  ])
}

/// Decode the data `turn_replay_to_json` wrote and complete the turn with
/// the text and calls the caller stored. It also reads Fabric's earlier
/// `llm_wire.turn.v1` data, whose `issues` list it ignores.
pub fn turn_replay_decoder(
  text: String,
  calls: List(ToolCall),
) -> decode.Decoder(AssistantTurn) {
  replay_fields(text, calls)
}

fn replay_fields(
  text: String,
  calls: List(ToolCall),
) -> decode.Decoder(AssistantTurn) {
  use provider <- decode.optional_field(
    "provider",
    None,
    decode.optional(provider_decoder()),
  )
  use response_id <- decode.optional_field(
    "response_id",
    None,
    decode.optional(decode.string),
  )
  use provider_data <- decode.optional_field(
    "provider_data",
    None,
    decode.optional(decode.string),
  )
  decode.success(AssistantTurn(
    provider:,
    text:,
    calls:,
    response_id:,
    provider_data:,
  ))
}

fn format_decoder(expected: String) -> decode.Decoder(Nil) {
  use format <- decode.optional_field("format", expected, decode.string)
  case format == expected {
    True -> decode.success(Nil)
    False -> decode.failure(Nil, expected)
  }
}

fn provider_to_json(provider: Provider) -> json.Json {
  let #(kind, name) = case provider {
    OpenAI -> #("openai", None)
    Anthropic -> #("anthropic", None)
    Google -> #("google", None)
    Custom(name) -> #("custom", Some(name))
  }
  json.object([
    #("kind", json.string(kind)),
    #("name", json.nullable(name, json.string)),
  ])
}

fn provider_decoder() -> decode.Decoder(Provider) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "openai" -> decode.success(OpenAI)
    "anthropic" -> decode.success(Anthropic)
    "google" -> decode.success(Google)
    "custom" ->
      decode.field("name", decode.string, fn(name) {
        decode.success(Custom(name))
      })
    _ -> decode.failure(OpenAI, "a known provider kind")
  }
}

fn call_to_json(call: ToolCall) -> json.Json {
  json.object([
    #("id", json.string(call.id)),
    #("name", json.string(call.name)),
    #("arguments", json.string(call.arguments_json)),
    #("provider_id", json.nullable(call.provider_id, json.string)),
    #("provider_state", json.nullable(call.provider_state, json.string)),
  ])
}

fn call_decoder() -> decode.Decoder(ToolCall) {
  use id <- decode.field("id", decode.string)
  use name <- decode.field("name", decode.string)
  use arguments_json <- decode.field("arguments", decode.string)
  use provider_id <- decode.optional_field(
    "provider_id",
    None,
    decode.optional(decode.string),
  )
  use provider_state <- decode.optional_field(
    "provider_state",
    None,
    decode.optional(decode.string),
  )
  decode.success(ToolCall(
    id:,
    name:,
    arguments_json:,
    provider_id:,
    provider_state:,
  ))
}

fn content_to_json(part: Content) -> json.Json {
  case part {
    TextPart(text) ->
      json.object([#("type", json.string("text")), #("text", json.string(text))])
    ImageUrlPart(url) ->
      json.object([
        #("type", json.string("image_url")),
        #("url", json.string(url)),
      ])
    InlineImagePart(mime_type, data) ->
      json.object([
        #("type", json.string("inline_image")),
        #("mime_type", json.string(mime_type)),
        #("data", json.string(data)),
      ])
  }
}

fn content_decoder() -> decode.Decoder(Content) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "text" ->
      decode.field("text", decode.string, fn(t) { decode.success(TextPart(t)) })
    "image_url" ->
      decode.field("url", decode.string, fn(u) {
        decode.success(ImageUrlPart(u))
      })
    "inline_image" -> {
      use mime_type <- decode.field("mime_type", decode.string)
      use data <- decode.field("data", decode.string)
      decode.success(InlineImagePart(mime_type, data))
    }
    _ -> decode.failure(TextPart(""), "a content part type")
  }
}
