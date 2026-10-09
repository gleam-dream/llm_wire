//// One inline Google audio transcription using the caller's HTTP Gun client.
////
//// Construct Audio under a raw-byte limit, prepare without I/O, then run once.
//// The caller owns HTTP limits, cancellation, deadlines, retries and storage.
//// Only completed nonempty text succeeds. Files, realtime audio, timestamps and
//// speaker data are outside this API. Neither cancellation nor a timeout proves
//// remote rollback. Request JSON contains audio and must be treated as sensitive.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/uri
import http_gun
import http_gun/error as http_error
import llm_wire
import llm_wire/error
import llm_wire/internal/json_bounds
import llm_wire/internal/observe
import llm_wire/internal/retry_after
import llm_wire/limit
import llm_wire/message
import llm_wire/telemetry

pub type Mode {
  Verbatim
  Smart
}

/// Model and language support are provider decisions. An empty language list
/// requests automatic detection. Use BCP-47 language hints when known.
pub type Settings {
  Settings(model: String, language_codes: List(String), mode: Mode)
}

pub fn settings(model: String) -> Settings {
  Settings(model, [], Verbatim)
}

/// Why raw audio admission failed. The MIME declaration does not validate an
/// audio codec, recording duration or acoustic quality.
pub type AudioError {
  InvalidAudio
  InvalidLimit
  UnsupportedMime
  AudioTooLarge(limit: Int, observed: Int)
}

pub opaque type Audio {
  Audio(bytes: BitArray, mime: String)
}

pub opaque type Config {
  Config(key: fn() -> String, endpoint: String, request_bytes: Int)
}

pub opaque type Prepared {
  Prepared(body: String, request: fn() -> request.Request(BitArray))
}

/// Pure Google Interactions configuration. Credentials are captured in a closure
/// and checked during preparation; ordinary value inspection cannot print them.
pub fn google(api_key: String) -> Config {
  let key = string.trim(api_key)
  Config(
    fn() { key },
    "https://generativelanguage.googleapis.com/v1beta/interactions",
    16_777_216,
  )
}

/// A complete HTTPS operation URL, subject to the supplied client's trust and
/// destination policy. Query, fragment, userinfo and control characters refuse.
pub fn with_endpoint(config: Config, endpoint: String) -> Config {
  Config(..config, endpoint:)
}

/// Bound encoded JSON after construction. This is separate from audio's raw
/// byte admission and the HTTP client's response allowance.
pub fn with_request_limit(config: Config, bytes: Int) -> Config {
  Config(..config, request_bytes: bytes)
}

/// Check raw bytes before Base64 expansion. The caller already owns this input
/// allocation. Supported MIME names follow Google's documented audio formats.
pub fn audio(
  bytes: BitArray,
  mime: String,
  max_bytes: Int,
) -> Result(Audio, AudioError) {
  let size = bit_array.byte_size(bytes)
  case size, bit_array.bit_size(bytes) % 8, max_bytes {
    _, _, max if max < 1 -> Error(InvalidLimit)
    0, _, _ -> Error(InvalidAudio)
    _, remainder, _ if remainder != 0 -> Error(InvalidAudio)
    _, _, _ if size > max_bytes -> Error(AudioTooLarge(max_bytes, size))
    _, _, _ ->
      case mime {
        "audio/wav"
        | "audio/mp3"
        | "audio/aiff"
        | "audio/aac"
        | "audio/ogg"
        | "audio/flac"
        | "audio/mpeg"
        | "audio/m4a"
        | "audio/l16"
        | "audio/opus"
        | "audio/alaw"
        | "audio/mulaw"
        | "audio/webm" -> Ok(Audio(bytes, mime))
        _ -> Error(UnsupportedMime)
      }
  }
}

/// Admit and encode with no timers, observations, socket or provider work.
/// A prepared value may be reused explicitly; it provides no deduplication.
pub fn prepare(
  config: Config,
  settings: Settings,
  input: Audio,
) -> Result(Prepared, error.PrepareError) {
  use Nil <- result.try(case config.request_bytes > 0 {
    True -> Ok(Nil)
    False ->
      Error(error.InvalidSetting(
        error.LimitSetting(limit.RequestBytes),
        "must be positive",
      ))
  })
  use endpoint <- result.try(admit_endpoint(config.endpoint))
  let model = string.trim(settings.model)
  use Nil <- result.try(case model == "" {
    True -> Error(error.InvalidSetting(error.Model, "must be nonempty"))
    False -> Ok(Nil)
  })
  let key = config.key()
  use Nil <- result.try(
    case key != "" && visible_ascii(bit_array.from_string(key)) {
      True -> Ok(Nil)
      False ->
        Error(error.InvalidSetting(
          error.ApiKey,
          "must be nonempty visible ASCII",
        ))
    },
  )
  let body = encode(Settings(..settings, model:), input) |> json.to_string
  use Nil <- result.try(case string.byte_size(body) > config.request_bytes {
    True ->
      Error(error.RequestTooLarge(
        limit.RequestBytes,
        config.request_bytes,
        string.byte_size(body),
      ))
    False -> Ok(Nil)
  })
  // Only this closure can construct a request containing the credential header.
  Ok(
    Prepared(body, fn() {
      endpoint
      |> request.set_method(http.Post)
      |> request.set_header("x-goog-api-key", key)
      |> request.set_header("content-type", "application/json")
      |> request.set_body(bit_array.from_string(body))
    }),
  )
}

/// The admitted body, without headers. It includes Base64 audio; do not log it.
pub fn request_json(prepared: Prepared) -> String {
  prepared.body
}

/// Perform exactly one attempt. The borrowed client view is used unchanged:
/// transport bounds, destination restrictions and cancellation remain effective.
/// Synchronous response interpretation has no independent preemption guarantee.
pub fn run(
  client: http_gun.Client,
  prepared: Prepared,
) -> Result(String, llm_wire.Failure) {
  let context =
    observe.Context(
      observe.new_call_id(),
      http_gun.correlation(client),
      "google",
    )
  observe.emit(context, telemetry.Started, telemetry.Accepted)
  let outcome = {
    use buffered <- result.try(
      http_gun.send(client, prepared.request())
      |> result.map_error(fn(problem) {
        failure(error.Http(problem), case http_error.evidence(problem) {
          http_error.NotSent -> llm_wire.NotSent
          http_error.MaybeSent -> llm_wire.MaybeSent
        })
      }),
    )
    observe.emit(context, telemetry.RequestSent, telemetry.ResponseStarted)
    case buffered.truncated {
      True ->
        Error(failure(
          error.Protocol("truncated transcription response"),
          llm_wire.MaybeSent,
        ))
      False ->
        decode_response(buffered.response)
        |> result.map_error(failure(_, llm_wire.Completed))
    }
  }
  observe.emit(context, telemetry.Terminal, case outcome {
    Ok(_) -> telemetry.Answered
    Error(_) -> telemetry.Failed
  })
  observe.emit(context, telemetry.Cleanup, telemetry.TransportClosed)
  outcome
}

fn failure(problem: error.Error, sent: llm_wire.Sent) -> llm_wire.Failure {
  llm_wire.Failure(problem, sent, False, message.Google, None)
}

fn visible_ascii(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bytes>> if byte >= 33 && byte <= 126 -> visible_ascii(rest)
    _ -> False
  }
}

fn admit_endpoint(
  url: String,
) -> Result(request.Request(String), error.PrepareError) {
  let refused =
    error.InvalidSetting(
      error.Endpoint,
      "requires an HTTPS host and path without userinfo, query, fragment or controls",
    )
  case uri.parse(url) {
    Ok(uri.Uri(Some("https"), None, Some(host), port, path, None, None)) -> {
      let valid_port = case port {
        None -> True
        Some(p) -> p > 0 && p <= 65_535
      }
      case
        host != ""
        && path != ""
        && valid_port
        && visible_ascii(bit_array.from_string(url))
      {
        True -> request.to(url) |> result.replace_error(refused)
        False -> Error(refused)
      }
    }
    _ -> Error(refused)
  }
}

fn encode(settings: Settings, input: Audio) -> json.Json {
  json.object([
    #("store", json.bool(False)),
    #("model", json.string(settings.model)),
    #(
      "input",
      json.array(
        [
          json.object([
            #("type", json.string("audio")),
            #("data", json.string(bit_array.base64_encode(input.bytes, True))),
            #("mime_type", json.string(input.mime)),
          ]),
        ],
        fn(value) { value },
      ),
    ),
    #(
      "generation_config",
      json.object([
        #(
          "transcription_config",
          json.object([
            #(
              "language_codes",
              json.array(settings.language_codes, json.string),
            ),
            #("mode", case settings.mode {
              Verbatim -> json.object([#("type", json.string("verbatim"))])
              Smart -> json.string("smart")
            }),
          ]),
        ),
      ]),
    ),
  ])
}

fn decode_response(
  reply: response.Response(BitArray),
) -> Result(String, error.Error) {
  use Nil <- result.try(case reply.status {
    200 -> Ok(Nil)
    status ->
      Error(error.Status(status, "", retry_after.from_headers(reply.headers)))
  })
  use body <- result.try(
    bit_array.to_string(reply.body)
    |> result.replace_error(error.Protocol(
      "transcription response is not UTF-8",
    )),
  )
  use Nil <- result.try(
    json_bounds.check_depth(body)
    |> result.replace_error(error.Protocol(
      "transcription JSON exceeds depth limit",
    )),
  )
  let decoder = {
    use status <- decode.field("status", decode.string)
    use steps <- decode.field("steps", decode.list(step_decoder()))
    decode.success(#(status, list.flatten(steps)))
  }
  use parsed <- result.try(
    json.parse(body, decoder)
    |> result.replace_error(error.Protocol("malformed transcription response")),
  )
  case parsed {
    #("completed", pieces) ->
      case string.trim(string.join(pieces, "")) {
        "" -> Error(error.Protocol("empty transcription"))
        text -> Ok(text)
      }
    _ -> Error(error.Protocol("incomplete transcription"))
  }
}

fn step_decoder() -> decode.Decoder(List(String)) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "model_output" -> {
      use pieces <- decode.field("content", decode.list(content_decoder()))
      decode.success(list.flatten(pieces))
    }
    _ -> decode.success([])
  }
}

fn content_decoder() -> decode.Decoder(List(String)) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "text" -> {
      use text <- decode.field("text", decode.string)
      decode.success([text])
    }
    _ -> decode.success([])
  }
}
