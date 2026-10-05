//// Bounded, typed classification beside chat generation.
////
//// Build questions with `classify/question`, prepare without I/O, then run
//// through your application-owned HTTP Gun client. TypeSafe System One is
//// the first wire. `wire` accepts another provider's encoding and decoding;
//// transport, limits, failures and correlated telemetry stay shared.
//// Confidence is provider concentration evidence, not answer correctness.

import gleam/option.{type Option}
import http_gun
import json/blueprint/codec
import json/blueprint/value.{type Value}
import llm_wire
import llm_wire/classify/protocol
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

/// The pure TypeSafe protocol, including stable receipt bounds.
pub fn typesafe() -> Wire {
  typesafe.wire()
}

/// Another wire projects the question vocabulary into its own protocol.
/// Both callbacks must be pure and must not capture credentials. Shared JSON
/// depth, value-count and numeric-token bounds precede decoding. The wire
/// checks its own mandatory fields and precise numbers before Float conversion;
/// shared admission checks candidate evidence against the authored questions.
pub fn wire(
  provider: message.Provider,
  endpoint: String,
  encode: fn(String, Value, List(#(String, protocol.QuestionView))) ->
    Result(String, error.PrepareError),
  decode: fn(String) -> Result(Decoded, error.Error),
) -> Wire {
  runtime.wire(provider, endpoint, encode, decode)
}

pub fn decoded(
  model: String,
  answers: List(#(String, protocol.Answer)),
  usage: Option(message.Usage),
) -> Decoded {
  runtime.Decoded(model, answers, usage)
}

/// Live settings contain no protocol. The key is a reveal closure and is
/// validated during preparation only after pure configuration admission.
pub fn config(reveal: fn() -> String) -> Config {
  runtime.config(reveal)
}

/// Replace Bearer authentication. The unused API key is never revealed.
pub fn with_headers(
  config: Config,
  headers: fn() -> List(#(String, String)),
) -> Config {
  runtime.with_headers(config, headers)
}

/// Stable request evidence allowance for this wire/operation version.
pub fn with_receipt_request_limit(wire: Wire, bytes: Int) -> Wire {
  runtime.with_receipt_request_limit(wire, bytes)
}

/// Stable response evidence allowance for this wire/operation version.
pub fn with_receipt_response_limit(wire: Wire, bytes: Int) -> Wire {
  runtime.with_receipt_response_limit(wire, bytes)
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

/// Reject incompatible live limits before revealing credentials or making I/O.
pub fn prepare(
  wire: Wire,
  config: Config,
  request: Request(a),
) -> Result(Prepared(a), error.PrepareError) {
  runtime.prepare(wire, config, request)
}

pub fn run(
  client: http_gun.Client,
  prepared: Prepared(a),
) -> Result(Outcome(a), llm_wire.Failure) {
  runtime.run(client, prepared)
}

/// A durable receipt codec captures only pure wire projections. It reads the
/// original bridge receipts as well as the provider-neutral receipt format.
/// The wire's fixed receipt request and response byte limits bound the saved
/// protocol evidence on encode and decode. The storage reader separately owns
/// the limit for the enclosing record, including escaping and stored state.
pub fn receipt_codec(
  wire: Wire,
  questions: question.Batch(a),
) -> codec.Codec(Outcome(a)) {
  runtime.receipt_codec(wire, questions)
}
