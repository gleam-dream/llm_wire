import gleam/bit_array
import gleam/http
import gleam/http/request as http_request
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/uri
import http_gun
import http_gun/config as http_config
import http_gun/destination
import http_gun/error as http_error
import json/blueprint/codec
import json/blueprint/value.{type Value}
import llm_wire
import llm_wire/classify/protocol
import llm_wire/classify/question
import llm_wire/error
import llm_wire/internal/classification/batch
import llm_wire/internal/classification/wire as json_wire
import llm_wire/internal/http_client
import llm_wire/internal/observe
import llm_wire/internal/retry_after
import llm_wire/limit
import llm_wire/message
import llm_wire/telemetry

pub opaque type Wire {
  Wire(
    provider: message.Provider,
    endpoint: String,
    request_bytes: Int,
    response_bytes: Int,
    encode: fn(String, Value, List(#(String, protocol.QuestionView))) ->
      Result(String, error.PrepareError),
    decode: fn(String) -> Result(Decoded, error.Error),
  )
}

pub type Decoded {
  Decoded(
    model: String,
    answers: List(#(String, protocol.Answer)),
    usage: Option(message.Usage),
  )
}

type Auth {
  ApiKey(reveal: fn() -> String)
  Headers(reveal: fn() -> List(#(String, String)))
}

pub opaque type Config {
  Config(
    auth: Auth,
    endpoint: Option(String),
    timeout: llm_wire.Bound,
    request_bytes: Int,
    response_bytes: Int,
  )
}

pub opaque type Request(a) {
  Request(model: String, state: Value, questions: question.Batch(a))
}

pub opaque type Prepared(a) {
  Prepared(
    wire: Wire,
    config: Config,
    request: Request(a),
    body: String,
    http: http_request.Request(Nil),
  )
}

pub type Outcome(a) {
  Outcome(
    answer: a,
    requested_model: String,
    resolved_model: String,
    usage: Option(message.Usage),
    request_json: String,
    response_json: String,
    state: Value,
  )
}

pub fn wire(
  provider: message.Provider,
  endpoint: String,
  encode: fn(String, Value, List(#(String, protocol.QuestionView))) ->
    Result(String, error.PrepareError),
  decode: fn(String) -> Result(Decoded, error.Error),
) -> Wire {
  Wire(
    provider:,
    endpoint:,
    request_bytes: 1_048_576,
    response_bytes: 1_048_576,
    encode:,
    decode:,
  )
}

pub fn config(reveal: fn() -> String) -> Config {
  Config(
    ApiKey(reveal),
    None,
    llm_wire.After(duration.seconds(600)),
    1_048_576,
    1_048_576,
  )
}

pub fn with_headers(
  config: Config,
  headers: fn() -> List(#(String, String)),
) -> Config {
  Config(..config, auth: Headers(headers))
}

pub fn with_endpoint(config: Config, endpoint: String) -> Config {
  Config(..config, endpoint: Some(endpoint))
}

pub fn with_receipt_request_limit(wire: Wire, bytes: Int) -> Wire {
  Wire(..wire, request_bytes: bytes)
}

pub fn with_receipt_response_limit(wire: Wire, bytes: Int) -> Wire {
  Wire(..wire, response_bytes: bytes)
}

pub fn with_timeout(config: Config, timeout: llm_wire.Bound) -> Config {
  Config(..config, timeout:)
}

pub fn with_request_limit(config: Config, bytes: Int) -> Config {
  Config(..config, request_bytes: bytes)
}

pub fn with_response_limit(config: Config, bytes: Int) -> Config {
  Config(..config, response_bytes: bytes)
}

pub fn request(
  model: String,
  state: Value,
  questions: question.Batch(a),
) -> Request(a) {
  Request(model:, state:, questions:)
}

pub fn prepare(
  wire: Wire,
  config: Config,
  request: Request(a),
) -> Result(Prepared(a), error.PrepareError) {
  use Nil <- result.try(compatible_limit(
    config.request_bytes,
    wire.request_bytes,
    limit.RequestBytes,
  ))
  use Nil <- result.try(compatible_limit(
    config.response_bytes,
    wire.response_bytes,
    limit.ResponseBodyBytes,
  ))
  let endpoint = option.unwrap(config.endpoint, wire.endpoint)
  use Nil <- result.try(validate_endpoint(endpoint))
  use Nil <- result.try(case string.trim(request.model) {
    "" -> Error(error.InvalidSetting(error.Model, "must be nonempty"))
    _ -> Ok(Nil)
  })
  use Nil <- result.try(case config.timeout {
    llm_wire.After(d) ->
      case duration.to_milliseconds(d) <= 0 {
        True ->
          Error(error.InvalidSetting(
            error.TimeoutSetting(error.WholeCall),
            "must be positive",
          ))
        False -> Ok(Nil)
      }
    _ -> Ok(Nil)
  })
  use http <- result.try(
    http_request.to(endpoint)
    |> result.replace_error(error.InvalidSetting(
      error.Endpoint,
      "invalid HTTP endpoint",
    )),
  )
  use body <- result.try(wire.encode(
    request.model,
    request.state,
    question.definitions(request.questions),
  ))
  use Nil <- result.try(check_request_size(body, config.request_bytes))
  use _ <- result.try(
    json_wire.parse(body)
    |> result.map_error(fn(problem) {
      error.InvalidRequest(
        error.InvalidClassificationContent(json_wire.describe_error(problem)),
      )
    }),
  )
  use Nil <- result.try(validate_auth(config.auth))
  Ok(Prepared(wire, config, request, body, http_request.set_body(http, Nil)))
}

fn check_request_size(
  body: String,
  bytes: Int,
) -> Result(Nil, error.PrepareError) {
  case string.byte_size(body) > bytes {
    True ->
      Error(error.RequestTooLarge(
        limit.RequestBytes,
        bytes,
        string.byte_size(body),
      ))
    False -> Ok(Nil)
  }
}

fn check_response_size(body: String, bytes: Int) -> Result(Nil, error.Error) {
  case string.byte_size(body) > bytes {
    True ->
      Error(error.LimitExceeded(
        limit.ResponseBodyBytes,
        bytes,
        string.byte_size(body),
      ))
    False -> Ok(Nil)
  }
}

/// Only the transport and redacting fixture builder reveal headers.
pub fn http_request(prepared: Prepared(a)) -> http_request.Request(BitArray) {
  let request =
    prepared.http
    |> http_request.set_method(http.Post)
    |> http_request.set_header("content-type", "application/json")
    |> http_request.set_header("accept", "application/json")
    |> http_request.set_header("accept-encoding", "identity")
    |> http_request.set_body(bit_array.from_string(prepared.body))
  list_headers(request, headers(prepared.config.auth))
}

fn list_headers(
  request: http_request.Request(a),
  headers: List(#(String, String)),
) -> http_request.Request(a) {
  case headers {
    [] -> request
    [#(key, value), ..rest] ->
      list_headers(http_request.set_header(request, key, value), rest)
  }
}

pub fn run(
  client: http_gun.Client,
  prepared: Prepared(a),
) -> Result(Outcome(a), llm_wire.Failure) {
  let config = prepared.config
  let context =
    observe.Context(
      observe.new_call_id(),
      http_gun.correlation(client),
      message.provider_name(prepared.wire.provider),
    )
  observe.emit(context, telemetry.Started, telemetry.Accepted)
  let client = case config.timeout {
    llm_wire.After(d) -> http_gun.with_timeout(client, http_config.After(d))
    llm_wire.Infinity -> http_gun.with_timeout(client, http_config.Infinity)
  }
  let client =
    http_gun.with_body_limit(client, config.response_bytes, http_gun.Fail)
  let client = case prepared.http.scheme {
    http.Https -> client
    http.Http ->
      http_gun.with_destination(
        client,
        destination.default()
          |> destination.allow_loopback
          |> destination.allow_private
          |> destination.with_plaintext(destination.PlaintextToLoopbackOnly),
      )
  }
  let outcome = {
    use buffered <- result.try(
      http_gun.send(client, http_request(prepared))
      |> result.map_error(fn(failure) {
        failure_for(
          prepared,
          http_client.wire_error(failure),
          case http_error.evidence(failure) {
            http_error.NotSent -> llm_wire.NotSent
            http_error.MaybeSent -> llm_wire.MaybeSent
          },
        )
      }),
    )
    observe.emit(context, telemetry.RequestSent, telemetry.ResponseStarted)
    let response = buffered.response
    use body <- result.try(
      bit_array.to_string(response.body)
      |> result.replace_error(failure_for(
        prepared,
        error.Protocol("classification response is not UTF-8"),
        llm_wire.Completed,
      )),
    )
    use Nil <- result.try(case response.status {
      200 -> Ok(Nil)
      status ->
        Error(failure_for(
          prepared,
          error.Status(status, "", retry_after.from_headers(response.headers)),
          llm_wire.Completed,
        ))
    })
    use decoded <- result.try(
      decode_body(prepared.wire.decode, body)
      |> result.map_error(failure_for(prepared, _, llm_wire.Completed)),
    )
    use answer <- result.map(
      question.decode(prepared.request.questions, decoded.answers)
      |> result.map_error(fn(problem) {
        failure_for(
          prepared,
          error.Protocol(question.describe_error(problem)),
          llm_wire.Completed,
        )
      }),
    )
    Outcome(
      answer,
      prepared.request.model,
      decoded.model,
      decoded.usage,
      prepared.body,
      body,
      prepared.request.state,
    )
  }
  observe.emit(context, telemetry.Terminal, case outcome {
    Ok(_) -> telemetry.Answered
    Error(_) -> telemetry.Failed
  })
  observe.emit(context, telemetry.Cleanup, telemetry.TransportClosed)
  outcome
}

fn failure_for(
  prepared: Prepared(a),
  error: error.Error,
  sent: llm_wire.Sent,
) -> llm_wire.Failure {
  llm_wire.Failure(error, sent, False, prepared.wire.provider, None)
}

/// Retained evidence is reconstructed without credentials or I/O. Capture
/// only the wire's pure projection functions, never its header closure.
pub fn receipt_codec(
  wire: Wire,
  questions: question.Batch(a),
) -> codec.Codec(Outcome(a)) {
  let encode_request = wire.encode
  let decode_response = wire.decode
  let request_bytes = wire.request_bytes
  let response_bytes = wire.response_bytes
  let restore = fn(model, state, request, response) {
    use Nil <- result.try(
      check_request_size(request, request_bytes)
      |> result.map_error(json_wire.PreparationFailed),
    )
    use Nil <- result.try(
      check_response_size(response, response_bytes)
      |> result.map_error(json_wire.ResponseFailed),
    )
    use expected <- result.try(
      encode_request(model, state, question.definitions(questions))
      |> result.map_error(json_wire.PreparationFailed),
    )
    use Nil <- result.try(
      check_request_size(expected, request_bytes)
      |> result.map_error(json_wire.PreparationFailed),
    )
    use sent <- result.try(json_wire.parse(request))
    use expected <- result.try(json_wire.parse(expected))
    use Nil <- result.try(json_wire.require(
      json_wire.canonical(sent) == json_wire.canonical(expected),
      "saved classifier questions differ from the deployed batch",
    ))
    use decoded <- result.try(
      decode_body(decode_response, response)
      |> result.map_error(json_wire.ResponseFailed),
    )
    use answer <- result.map(
      question.decode(questions, decoded.answers)
      |> result.map_error(fn(problem) {
        json_wire.InvalidValue(question.describe_error(problem))
      }),
    )
    Outcome(
      answer,
      model,
      decoded.model,
      decoded.usage,
      request,
      response,
      state,
    )
  }
  codec.custom(
    encode: fn(receipt: Outcome(a)) {
      use reconstructed <- result.try(
        restore(
          receipt.requested_model,
          receipt.state,
          receipt.request_json,
          receipt.response_json,
        )
        |> result.map_error(fn(problem) {
          codec.encode_failure(json_wire.describe_error(problem))
        }),
      )
      use Nil <- result.map(
        json_wire.require(
          reconstructed == receipt,
          "native classifier receipt differs from its protocol evidence",
        )
        |> result.map_error(fn(problem) {
          codec.encode_failure(json_wire.describe_error(problem))
        }),
      )
      value.Array([
        value.String("llm.classification.receipt.v1"),
        value.String(receipt.requested_model),
        receipt.state,
        value.String(receipt.request_json),
        value.String(receipt.response_json),
      ])
    },
    decode: fn(saved) {
      let decoded = case saved {
        value.Array([
          value.String("llm.classification.receipt.v1"),
          value.String(model),
          state,
          value.String(request),
          value.String(response),
        ]) -> restore(model, state, request, response)
        // Original TypeSafe bridge receipts have no separate model or state.
        value.Array([
          value.String("fabric.typesafe.receipt.v1"),
          value.String(request),
          value.String(response),
        ]) -> {
          use Nil <- result.try(
            check_request_size(request, request_bytes)
            |> result.map_error(json_wire.PreparationFailed),
          )
          use fields <- result.try(
            json_wire.parse(request) |> result.try(json_wire.object),
          )
          use model <- result.try(
            json_wire.required(fields, "model") |> result.try(json_wire.text),
          )
          use state <- result.try(json_wire.required(fields, "state"))
          restore(model, state, request, response)
        }
        _ -> Error(json_wire.InvalidValue("invalid classifier receipt format"))
      }
      decoded
      |> result.map_error(fn(problem) {
        codec.decode_failure(json_wire.describe_error(problem))
      })
    },
    schema: None,
    placeholder: Outcome(
      batch.placeholder(questions),
      "",
      "",
      None,
      "",
      "",
      value.Null,
    ),
  )
}

fn compatible_limit(
  live: Int,
  receipt: Int,
  kind: limit.Limit,
) -> Result(Nil, error.PrepareError) {
  case live > 0 && receipt > 0 && live <= receipt {
    True -> Ok(Nil)
    False ->
      Error(error.InvalidSetting(
        error.LimitSetting(kind),
        "live and receipt limits must be positive; live limit must not exceed the fixed receipt limit",
      ))
  }
}

fn validate_auth(auth: Auth) -> Result(Nil, error.PrepareError) {
  case auth {
    Headers(_) -> Ok(Nil)
    ApiKey(reveal) -> {
      let key = reveal()
      case
        key != ""
        && list.all(string.to_utf_codepoints(key), fn(c) {
          let n = string.utf_codepoint_to_int(c)
          n > 32 && n < 127
        })
      {
        True -> Ok(Nil)
        False ->
          Error(error.InvalidSetting(
            error.ApiKey,
            "must be nonempty visible ASCII",
          ))
      }
    }
  }
}

fn headers(auth: Auth) -> List(#(String, String)) {
  case auth {
    Headers(reveal) -> reveal()
    ApiKey(reveal) -> [#("authorization", "Bearer " <> reveal())]
  }
}

fn decode_body(
  decode: fn(String) -> Result(Decoded, error.Error),
  body: String,
) -> Result(Decoded, error.Error) {
  use _ <- result.try(
    json_wire.parse(body)
    |> result.map_error(fn(problem) {
      error.Protocol(json_wire.describe_error(problem))
    }),
  )
  decode(body) |> result.try(admit_decoded)
}

fn admit_decoded(decoded: Decoded) -> Result(Decoded, error.Error) {
  use Nil <- result.try(case decoded.usage {
    None -> Ok(Nil)
    Some(usage) ->
      case
        usage.input_tokens >= 0
        && usage.output_tokens >= 0
        && usage.total_tokens >= 0
      {
        True -> Ok(Nil)
        False -> Error(error.Protocol("negative classifier token usage"))
      }
  })
  case string.trim(decoded.model) == "" {
    True -> Error(error.Protocol("empty classifier response model"))
    False -> Ok(decoded)
  }
}

fn validate_endpoint(url: String) -> Result(Nil, error.PrepareError) {
  let refused =
    Error(error.InvalidSetting(
      error.Endpoint,
      "requires an HTTP(S) host and path without userinfo, query, fragment or controls",
    ))
  case uri.parse(url) {
    Ok(uri.Uri(Some(scheme), None, Some(host), port, path, None, None)) -> {
      let valid_port = case port {
        None -> True
        Some(p) -> p > 0 && p <= 65_535
      }
      let valid_chars =
        !string.contains(url, "\n")
        && !string.contains(url, "\r")
        && !string.contains(url, " ")
      case
        host != ""
        && path != ""
        && valid_port
        && valid_chars
        && {
          scheme == "https"
          || scheme == "http"
          && { host == "127.0.0.1" || host == "localhost" || host == "::1" }
        }
      {
        True -> Ok(Nil)
        False -> refused
      }
    }
    _ -> refused
  }
}
