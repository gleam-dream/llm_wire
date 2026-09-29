//// Offline HTTP playback through the ordinary provider/session pipeline.
//// Loading and starting are explicit; configuration remains a pure value.
//// Cassette files contain no request headers. Request and response bodies can
//// contain application data, so callers choose where fixtures may be stored.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import llm_wire/internal/json_bounds
import llm_wire/testing

/// A validated, ordered collection of request/reply pairs.
pub opaque type Cassette {
  Cassette(exchanges: List(testing.Exchange))
}

pub type Error {
  InvalidLimit(limit: Int)
  TooLarge(limit: Int, measured: Int)
  InvalidJson
  UnsupportedVersion(version: Int)
  /// `index` is one-based in the ordered exchange list.
  InvalidExchange(index: Int, reason: String)
  ReadError(reason: String)
  InvalidUtf8
  TooDeep
}

/// Builds a fixture without starting a process or opening a file.
pub fn new(exchanges: List(testing.Exchange)) -> Result(Cassette, Error) {
  use Nil <- result.try(validate_exchanges(exchanges, 1))
  Ok(Cassette(exchanges))
}

fn validate_exchanges(
  exchanges: List(testing.Exchange),
  index: Int,
) -> Result(Nil, Error) {
  case exchanges {
    [] -> Ok(Nil)
    [exchange, ..rest] -> {
      use Nil <- result.try(
        validate_exchange(exchange)
        |> result.map_error(fn(reason) { InvalidExchange(index, reason) }),
      )
      validate_exchanges(rest, index + 1)
    }
  }
}

fn validate_exchange(exchange: testing.Exchange) -> Result(Nil, String) {
  let request = exchange.request
  use Nil <- result.try(case request.method {
    "POST" -> Ok(Nil)
    _ -> Error("LLM Wire exchanges use POST")
  })
  use endpoint <- result.try(
    uri.parse(request.endpoint)
    |> result.map_error(fn(_) { "Invalid endpoint URL" }),
  )
  use Nil <- result.try(case endpoint {
    uri.Uri(
      scheme: Some(scheme),
      host: Some(host),
      userinfo: None,
      query: None,
      fragment: None,
      ..,
    )
      if host != "" && { scheme == "https" || scheme == "http" }
    -> Ok(Nil)
    _ ->
      Error(
        "Endpoint must be HTTP(S), with a host and no credentials, query or fragment",
      )
  })
  use Nil <- result.try(
    case
      string.starts_with(request.path, "/")
      && !string.contains(request.path, "#")
    {
      True -> Ok(Nil)
      False -> Error("Expected an absolute request path without a fragment")
    },
  )
  case exchange.reply {
    testing.Events(_) | testing.Interrupted(_) -> Ok(Nil)
    testing.Status(code, _) if code >= 100 && code <= 599 && code != 200 ->
      Ok(Nil)
    testing.Status(_, _) ->
      Error(
        "Status replies require an HTTP code from 100 to 599 other than 200",
      )
  }
}

/// Reads at most `max_bytes + 1` bytes before decoding. For oversized files,
/// `TooLarge.measured` is the observed lower bound, not the full file size.
/// Files must contain UTF-8 JSON. Every read closes its file handle.
pub fn load(path: String, max_bytes: Int) -> Result(Cassette, Error) {
  use Nil <- result.try(check_limit(max_bytes))
  use bytes <- result.try(
    read_bounded(path, max_bytes + 1)
    |> result.map_error(ReadError),
  )
  use Nil <- result.try(case bit_array.byte_size(bytes) > max_bytes {
    True -> Error(TooLarge(max_bytes, bit_array.byte_size(bytes)))
    False -> Ok(Nil)
  })
  use raw <- result.try(
    bit_array.to_string(bytes)
    |> result.map_error(fn(_) { InvalidUtf8 }),
  )
  parse(raw, max_bytes)
}

@external(erlang, "llm_wire_cassette_ffi", "read_bounded")
fn read_bounded(path: String, bytes: Int) -> Result(BitArray, String)

/// Parses version 1 data. `max_bytes` must be positive and bounds UTF-8 bytes.
/// JSON nesting is limited to 64 containers before decoding.
pub fn parse(raw: String, max_bytes: Int) -> Result(Cassette, Error) {
  use Nil <- result.try(check_size(raw, max_bytes))
  use Nil <- result.try(
    json_bounds.check_depth(raw)
    |> result.map_error(fn(_) { TooDeep }),
  )
  use version <- result.try(
    json.parse(raw, decode.field("version", decode.int, decode.success))
    |> result.map_error(fn(_) { InvalidJson }),
  )
  use Nil <- result.try(case version {
    1 -> Ok(Nil)
    other -> Error(UnsupportedVersion(other))
  })
  use exchanges <- result.try(
    json.parse(
      raw,
      decode.field("exchanges", decode.list(exchange_decoder()), decode.success),
    )
    |> result.map_error(fn(_) { InvalidJson }),
  )
  new(exchanges)
}

/// Serializes a fixture without writing it. Size is checked after encoding.
pub fn to_json(cassette: Cassette, max_bytes: Int) -> Result(String, Error) {
  use Nil <- result.try(check_limit(max_bytes))
  let raw =
    json.object([
      #("version", json.int(1)),
      #("exchanges", json.array(cassette.exchanges, encode_exchange)),
    ])
    |> json.to_string
  use Nil <- result.try(check_size(raw, max_bytes))
  Ok(raw)
}

/// Starts an ordered script. Use `testing.with_script(settings, script)` to
/// select playback for an otherwise unchanged flow. There is no live fallback.
/// The script process is linked to the caller that starts it.
pub fn start(cassette: Cassette) -> testing.Script {
  testing.start_matched(cassette.exchanges)
}

fn check_size(raw: String, max_bytes: Int) -> Result(Nil, Error) {
  use Nil <- result.try(check_limit(max_bytes))
  case string.byte_size(raw) > max_bytes {
    True -> Error(TooLarge(max_bytes, string.byte_size(raw)))
    False -> Ok(Nil)
  }
}

fn check_limit(max_bytes: Int) -> Result(Nil, Error) {
  case max_bytes > 0 {
    True -> Ok(Nil)
    False -> Error(InvalidLimit(max_bytes))
  }
}

fn exchange_decoder() -> decode.Decoder(testing.Exchange) {
  use request <- decode.field("request", request_decoder())
  use reply <- decode.field("reply", reply_decoder())
  decode.success(testing.Exchange(request, reply))
}

fn request_decoder() -> decode.Decoder(testing.ExpectedRequest) {
  use method <- decode.field("method", decode.string)
  use endpoint <- decode.field("endpoint", decode.string)
  use path <- decode.field("path", decode.string)
  use body <- decode.field("body", decode.string)
  decode.success(testing.ExpectedRequest(method, endpoint, path, body))
}

fn reply_decoder() -> decode.Decoder(testing.Reply) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "events" -> {
      use chunks <- decode.field("chunks", decode.list(decode.string))
      decode.success(testing.Events(chunks))
    }
    "interrupted" -> {
      use chunks <- decode.field("chunks", decode.list(decode.string))
      decode.success(testing.Interrupted(chunks))
    }
    "status" -> {
      use code <- decode.field("code", decode.int)
      use body <- decode.field("body", decode.string)
      decode.success(testing.Status(code, body))
    }
    _ ->
      decode.failure(testing.Events([]), "events, interrupted or status reply")
  }
}

fn encode_exchange(exchange: testing.Exchange) -> json.Json {
  let request = exchange.request
  json.object([
    #(
      "request",
      json.object([
        #("method", json.string(request.method)),
        #("endpoint", json.string(request.endpoint)),
        #("path", json.string(request.path)),
        #("body", json.string(request.body)),
      ]),
    ),
    #("reply", encode_reply(exchange.reply)),
  ])
}

fn encode_reply(reply: testing.Reply) -> json.Json {
  case reply {
    testing.Events(chunks) ->
      json.object([
        #("kind", json.string("events")),
        #("chunks", json.array(chunks, json.string)),
      ])
    testing.Interrupted(chunks) ->
      json.object([
        #("kind", json.string("interrupted")),
        #("chunks", json.array(chunks, json.string)),
      ])
    testing.Status(code, body) ->
      json.object([
        #("kind", json.string("status")),
        #("code", json.int(code)),
        #("body", json.string(body)),
      ])
  }
}
