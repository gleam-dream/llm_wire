//// Reads the provider's own error code and message from an error response
//// body. The three built-in providers nest both under `error`:
////
//// - OpenAI: `{"error": {"message", "type", "param", "code"}}`; `code` can be
////   null, and `type` names the error then.
//// - Anthropic: `{"type": "error", "error": {"type", "message"}}`.
//// - Google: `{"error": {"code": 429, "message", "status"}}`, where `status`
////   is the canonical code and `code` repeats the HTTP status.
////
//// An OpenAI-compatible server or a custom provider that uses one of these
//// envelopes is read the same way. A body without one yields no code and
//// no message.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}

/// The provider's error code and message, each `None` when the body does
/// not carry it.
pub fn read(body: String) -> #(Option(String), Option(String)) {
  case json.parse(body, decode.at(["error"], envelope())) {
    Ok(found) -> found
    Error(_) -> #(None, None)
  }
}

fn envelope() -> decode.Decoder(#(Option(String), Option(String))) {
  use status <- decode.then(optional_string("status"))
  use code <- decode.then(optional_string("code"))
  use type_ <- decode.then(optional_string("type"))
  use message <- decode.then(optional_string("message"))
  let code = case status, code, type_ {
    Some(status), _, _ -> Some(status)
    None, Some(code), _ -> Some(code)
    None, None, type_ -> type_
  }
  decode.success(#(code, message))
}

/// A string member, or `None` when it is absent, null or not a string.
fn optional_string(name: String) -> decode.Decoder(Option(String)) {
  decode.one_of(decode.at([name], decode.map(decode.string, Some)), [
    decode.success(None),
  ])
}
