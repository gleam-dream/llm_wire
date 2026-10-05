//// Bounded, typed classification beside chat generation.
////
//// Build questions with `classify/question`, prepare without I/O, then run
//// through your application-owned HTTP Gun client. TypeSafe System One is
//// the first wire. `wire` accepts another provider's encoding and decoding;
//// transport, limits, failures and correlated telemetry stay shared.
//// Confidence is provider concentration evidence, not answer correctness.

import http_gun
import json/blueprint/codec
import json/blueprint/value.{type Value}
import llm_wire
import llm_wire/classify/question
import llm_wire/error
import llm_wire/internal/classification/runtime
import llm_wire/internal/classification/typesafe
import llm_wire/message

pub type Config =
  runtime.Config

pub type Wire =
  runtime.Wire

pub type Request(a) =
  runtime.Request(a)

pub type Prepared(a) =
  runtime.Prepared(a)

pub type Outcome(a) =
  runtime.Outcome(a)

pub type Decoded =
  runtime.Decoded

/// Credentials are revealed only inside the request's header closure.
pub fn typesafe(reveal: fn() -> String) -> Config {
  typesafe.wire(reveal) |> runtime.config
}

/// Another wire projects the question vocabulary into its own protocol.
pub fn wire(
  provider: message.Provider,
  endpoint: String,
  headers: fn() -> List(#(String, String)),
  encode: fn(String, Value, Value) -> Result(String, error.PrepareError),
  decode: fn(String) -> Result(Decoded, error.Error),
) -> Wire {
  runtime.wire(provider, endpoint, headers, encode, decode)
}

pub fn decoded(model: String, answers: Value, usage: message.Usage) -> Decoded {
  runtime.Decoded(model, answers, usage)
}

pub fn config(wire: Wire) -> Config {
  runtime.config(wire)
}

pub fn with_endpoint(config: Config, url: String) -> Config {
  runtime.with_endpoint(config, url)
}

pub fn with_timeout(config: Config, timeout: llm_wire.Bound) -> Config {
  runtime.with_timeout(config, timeout)
}

pub fn with_request_limit(config: Config, bytes: Int) -> Config {
  runtime.with_request_limit(config, bytes)
}

pub fn with_response_limit(config: Config, bytes: Int) -> Config {
  runtime.with_response_limit(config, bytes)
}

pub fn request(
  model: String,
  state: Value,
  questions: question.Batch(a),
) -> Request(a) {
  runtime.request(model, state, questions)
}

pub fn prepare(
  config: Config,
  request: Request(a),
) -> Result(Prepared(a), error.PrepareError) {
  runtime.prepare(config, request)
}

pub fn run(
  client: http_gun.Client,
  prepared: Prepared(a),
) -> Result(Outcome(a), llm_wire.Failure) {
  runtime.run(client, prepared)
}

/// A durable receipt codec captures only pure wire projections. It reads the
/// original bridge receipts as well as the provider-neutral receipt format.
/// The configuration's request and response byte limits also bound the saved
/// protocol evidence on encode and decode. The storage reader separately owns
/// the limit for the enclosing record, including escaping and stored state.
pub fn receipt_codec(
  config: Config,
  questions: question.Batch(a),
) -> codec.Codec(Outcome(a)) {
  runtime.receipt_codec(config, questions)
}
