import gleam/bit_array
import gleam/http
import gleam/http/request as http_request
import gleam/option.{None, Some}
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
    validate: fn() -> Result(Nil, error.PrepareError),
    provider: message.Provider,
    endpoint: String,
    headers: fn() -> List(#(String, String)),
    encode: fn(String, Value, Value) -> Result(String, error.PrepareError),
    decode: fn(String) -> Result(Decoded, error.Error),
  )
}

pub type Decoded {
  Decoded(model: String, answers: Value, usage: message.Usage)
}

pub opaque type Config {
  Config(
    wire: Wire,
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
    usage: message.Usage,
    request_json: String,
    response_json: String,
    state: Value,
  )
}

pub fn wire(
  provider: message.Provider,
  endpoint: String,
  headers: fn() -> List(#(String, String)),
  encode: fn(String, Value, Value) -> Result(String, error.PrepareError),
  decode: fn(String) -> Result(Decoded, error.Error),
) -> Wire {
  Wire(
    validate: fn() { Ok(Nil) },
    provider:,
    endpoint:,
    headers:,
    encode:,
    decode:,
  )
}

pub fn config(wire: Wire) -> Config {
  Config(wire, llm_wire.After(duration.seconds(600)), 1_048_576, 1_048_576)
}

pub fn with_endpoint(config: Config, endpoint: String) -> Config {
  Config(..config, wire: Wire(..config.wire, endpoint:))
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
  config: Config,
  request: Request(a),
) -> Result(Prepared(a), error.PrepareError) {
  use Nil <- result.try(config.wire.validate())
  use Nil <- result.try(validate_endpoint(config.wire.endpoint))
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
  use Nil <- result.try(
    case config.request_bytes > 0 && config.response_bytes > 0 {
      True -> Ok(Nil)
      False ->
        Error(error.InvalidSetting(
          error.LimitSetting(limit.ResponseBodyBytes),
          "limits must be positive",
        ))
    },
  )
  use http <- result.try(
    http_request.to(config.wire.endpoint)
    |> result.replace_error(error.InvalidSetting(
      error.Endpoint,
      "invalid HTTP endpoint",
    )),
  )
  use body <- result.try(config.wire.encode(
    request.model,
    request.state,
    question.definitions(request.questions),
  ))
  use Nil <- result.try(case string.byte_size(body) > config.request_bytes {
    True ->
      Error(error.RequestTooLarge(
        limit.RequestBytes,
        config.request_bytes,
        string.byte_size(body),
      ))
    False -> Ok(Nil)
  })
  Ok(Prepared(config, request, body, http_request.set_body(http, Nil)))
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
  list_headers(request, prepared.config.wire.headers())
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
      message.provider_name(config.wire.provider),
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
      config.wire.decode(body)
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
  llm_wire.Failure(error, sent, False, prepared.config.wire.provider, None)
}

/// Retained evidence is reconstructed without credentials or I/O. Capture
/// only the wire's pure projection functions, never its header closure.
pub fn receipt_codec(
  config: Config,
  questions: question.Batch(a),
) -> codec.Codec(Outcome(a)) {
  let encode_request = config.wire.encode
  let decode_response = config.wire.decode
  let restore = fn(model, state, request, response) {
    use expected <- result.try(
      encode_request(model, state, question.definitions(questions))
      |> result.map_error(error.describe_prepare_error),
    )
    use sent <- result.try(json_wire.parse(request))
    use expected <- result.try(json_wire.parse(expected))
    use Nil <- result.try(json_wire.require(
      json_wire.canonical(sent) == json_wire.canonical(expected),
      "saved classifier questions differ from the deployed batch",
    ))
    use decoded <- result.try(
      decode_response(response) |> result.map_error(error.describe),
    )
    use answer <- result.map(
      question.decode(questions, decoded.answers)
      |> result.map_error(question.describe_error),
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
        |> result.map_error(codec.encode_failure),
      )
      use Nil <- result.map(
        json_wire.require(
          reconstructed == receipt,
          "native classifier receipt differs from its protocol evidence",
        )
        |> result.map_error(codec.encode_failure),
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
          use fields <- result.try(
            json_wire.parse(request) |> result.try(json_wire.object),
          )
          use model <- result.try(
            json_wire.required(fields, "model") |> result.try(json_wire.text),
          )
          use state <- result.try(json_wire.required(fields, "state"))
          restore(model, state, request, response)
        }
        _ -> Error("invalid classifier receipt format")
      }
      decoded |> result.map_error(codec.decode_failure)
    },
    schema: None,
    placeholder: Outcome(
      batch.placeholder(questions),
      "",
      "",
      message.Usage(0, 0, 0),
      "",
      "",
      value.Null,
    ),
  )
}

pub fn with_validation(
  wire: Wire,
  validate: fn() -> Result(Nil, error.PrepareError),
) -> Wire {
  Wire(..wire, validate:)
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
