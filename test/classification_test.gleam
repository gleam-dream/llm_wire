import classification_live_scenario
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/cassette
import http_gun/config as http_config
import http_gun/error as http_error
import http_gun/testing as http_testing
import json/blueprint/codec
import json/blueprint/value
import llm_wire
import llm_wire/classify
import llm_wire/classify/protocol
import llm_wire/classify/question
import llm_wire/error
import llm_wire/internal/classification/runtime
import llm_wire/limit
import llm_wire/message
import llm_wire/telemetry
import llm_wire/testing
import sinal
import sinal/correlation

fn config() -> classify.Config {
  classify.config(fn() { "classification-fixture-secret" })
}

fn request() -> classify.Request(question.Noul) {
  classify.request(
    "jev-latest",
    value.String("2 + 2 = 4"),
    question.ask("correct", question.noul(value.String("Is it correct?"), None)),
  )
}

fn prepared() -> classify.Prepared(question.Noul) {
  classify.prepare(classify.typesafe(), config(), request()) |> should.be_ok
}

fn reply() -> testing.ClassificationReply {
  testing.classification_response(
    "{\"model\":\"fixture\",\"answers\":{\"correct\":{\"type\":\"noul\",\"noul\":0.9}},\"usage\":{\"input_tokens\":12,\"output_tokens\":8}}",
  )
}

pub fn classification_cassette_round_trip_and_correlated_telemetry_test() {
  let call = prepared()
  let encoded =
    cassette.encode(
      http_testing.script([testing.classification_exchange(call, reply())]),
    )
  string.contains(encoded, "classification-fixture-secret") |> should.be_false
  string.contains(string.inspect(call), "classification-fixture-secret")
  |> should.be_false
  let tape = cassette.parse(encoded, 100_000) |> should.be_ok
  let http = http_testing.playback(tape, http_config.default()) |> should.be_ok
  let correlation = correlation.unique()
  let seen = process.new_subject()
  let attachment =
    sinal.observe(telemetry.event(), fn(_, meta) {
      case meta.correlation == Some(correlation) {
        True -> process.send(seen, meta.stage)
        False -> Nil
      }
    })
  let answer =
    classify.run(http_gun.with_correlation(http, correlation), call)
    |> should.be_ok
  answer.answer.yes |> should.equal(0.9)
  answer.requested_model |> should.equal("jev-latest")
  answer.resolved_model |> should.equal("fixture")
  option.unwrap(answer.usage, message.Usage(0, 0, 0)).total_tokens
  |> should.equal(20)
  process.receive(seen, 1000) |> should.equal(Ok(telemetry.Started))
  process.receive(seen, 1000) |> should.equal(Ok(telemetry.RequestSent))
  process.receive(seen, 1000) |> should.equal(Ok(telemetry.Terminal))
  process.receive(seen, 1000) |> should.equal(Ok(telemetry.Cleanup))
  let _ = sinal.detach(attachment)
  http_gun.stop(http)
}

pub fn classification_limits_and_timeouts_are_validated_before_dispatch_test() {
  classify.prepare(
    classify.typesafe(),
    config() |> classify.with_timeout(llm_wire.After(duration.milliseconds(-1))),
    request(),
  )
  |> should.be_error
  classify.prepare(
    classify.typesafe(),
    config() |> classify.with_request_limit(1),
    request(),
  )
  |> should.be_error
  classify.prepare(
    classify.typesafe(),
    config() |> classify.with_response_limit(0),
    request(),
  )
  |> should.be_error
  classify.prepare(
    classify.typesafe(),
    config() |> classify.with_endpoint("not a URL"),
    request(),
  )
  |> should.be_error
  classify.prepare(
    classify.typesafe(),
    config() |> classify.with_timeout(llm_wire.Infinity),
    request(),
  )
  |> should.be_ok
}

pub fn classification_status_keeps_retry_after_and_completed_evidence_test() {
  let call = prepared()
  let reply =
    reply()
    |> testing.with_classification_status(429)
    |> testing.with_classification_header("retry-after", "9")
  let http =
    http_testing.playback(
      http_testing.script([testing.classification_exchange(call, reply)]),
      http_config.default(),
    )
    |> should.be_ok
  let failure = classify.run(http, call) |> should.be_error
  failure.sent |> should.equal(llm_wire.Completed)
  error.kind(failure.error) |> should.equal(error.ProviderError)
  llm_wire.advise(failure)
  |> should.equal(llm_wire.RetryAdvice(
    llm_wire.MayHelp,
    llm_wire.ProviderDelay(duration.seconds(9)),
  ))
  http_gun.stop(http)
}

pub fn classification_malformed_answer_is_typed_and_not_retried_test() {
  let call = prepared()
  let http =
    http_testing.playback(
      http_testing.script([
        testing.classification_exchange(
          call,
          testing.classification_response("{}"),
        ),
      ]),
      http_config.default(),
    )
    |> should.be_ok
  let failure = classify.run(http, call) |> should.be_error
  failure.sent |> should.equal(llm_wire.Completed)
  error.kind(failure.error) |> should.equal(error.UnusableResponse)
  let second = classify.run(http, call) |> should.be_error
  second.sent |> should.equal(llm_wire.NotSent)
  http_gun.stop(http)
}

pub fn forged_native_receipts_cannot_be_encoded_test() {
  let call = prepared()
  let http =
    http_testing.playback(
      http_testing.script([testing.classification_exchange(call, reply())]),
      http_config.default(),
    )
    |> should.be_ok
  let receipt = classify.run(http, call) |> should.be_ok
  let questions =
    question.ask("correct", question.noul(value.String("Is it correct?"), None))
  let codec = classify.receipt_codec(classify.typesafe(), questions)
  codec.encode(
    codec,
    runtime.Outcome(..receipt, usage: Some(message.Usage(0, 0, 0))),
  )
  |> should.be_error
  codec.encode(codec, runtime.Outcome(..receipt, resolved_model: "other"))
  |> should.be_error
  http_gun.stop(http)
}

pub fn live_typesafe_cassette_replays_all_three_question_kinds_offline_test() {
  let call = classification_live_scenario.prepared(fn() { "offline-key" })
  let tape =
    cassette.load("test/cassettes/live/typesafe-classification.json", 1_000_000)
    |> should.be_ok
  let http = http_testing.playback(tape, http_config.default()) |> should.be_ok
  let answer = classify.run(http, call) |> should.be_ok
  answer.resolved_model |> should.equal("jev-1.13.0")
  let #(yes, #(choice, score)) = answer.answer
  { yes.yes >=. 0.0 && yes.yes <=. 1.0 } |> should.be_true
  choice.selected |> should.equal(classification_live_scenario.Approve)
  score.levels
  |> should.equal([
    value.String("incorrect"),
    value.String("partial"),
    value.String("correct"),
  ])
  http_gun.stop(http)
}

pub fn raised_classification_request_limit_accepts_large_state_test() {
  let state = value.String(string.repeat("x", 1_048_577))
  let large = classify.request("fixture", state, receipt_questions())
  classify.prepare(
    large_wire(),
    config() |> classify.with_request_limit(2_097_152),
    large,
  )
  |> should.be_ok
  let failed =
    classify.prepare(classify.typesafe(), config(), large) |> should.be_error
  let assert error.RequestTooLarge(kind, limit, actual) = failed
  kind |> should.equal(limit.RequestBytes)
  limit |> should.equal(1_048_576)
  { actual > limit } |> should.be_true
}

pub fn raised_classification_response_limit_and_receipts_share_bounds_test() {
  let settings = config() |> classify.with_response_limit(2_097_152)
  let call = classify.prepare(large_wire(), settings, request()) |> should.be_ok
  let response =
    "{\"model\":\"fixture\",\"answers\":{\"correct\":{\"type\":\"noul\",\"noul\":0.9}},\"usage\":{\"input_tokens\":12,\"output_tokens\":8},\"padding\":\""
    <> string.repeat("x", 1_048_577)
    <> "\"}"
  let http =
    http_testing.playback(
      http_testing.script([
        testing.classification_exchange(
          call,
          testing.classification_response(response),
        ),
      ]),
      http_config.default() |> http_config.with_max_buffered_bytes(2_097_152),
    )
    |> should.be_ok
  let answer = classify.run(http, call) |> should.be_ok
  answer.answer.yes |> should.equal(0.9)
  let receipt = classify.receipt_codec(large_wire(), receipt_questions())
  let saved = codec.encode(receipt, answer) |> should.be_ok
  codec.decode(receipt, saved) |> should.equal(Ok(answer))
  let bounded = classify.receipt_codec(classify.typesafe(), receipt_questions())
  codec.decode(bounded, saved) |> should.be_error
  codec.encode(bounded, answer) |> should.be_error
  http_gun.stop(http)
}

fn receipt_questions() -> question.Batch(question.Noul) {
  question.ask("correct", question.noul(value.String("Is it correct?"), None))
}

pub fn configured_response_limit_is_enforced_before_classification_decode_test() {
  let response = padded_response("\"" <> string.repeat("x", 1_048_577) <> "\"")
  let failed =
    replay_classification(config(), request(), response) |> should.be_error
  let assert error.Http(transport) = failed.error
  let assert http_error.LimitExceeded(kind, cap, observed) =
    http_error.reason(transport)
  kind |> should.equal(http_error.ResponseBodyBytes)
  cap |> should.equal(1_048_576)
  observed |> should.equal(string.byte_size(response))
  failed.sent |> should.equal(llm_wire.MaybeSent)
}

pub fn raised_request_receipts_keep_legacy_shape_and_explicit_byte_budget_test() {
  let large =
    classify.request(
      "fixture",
      value.String(string.repeat("x", 1_048_577)),
      receipt_questions(),
    )
  let settings = config() |> classify.with_request_limit(2_097_152)
  let answer =
    replay_classification(settings, large, padded_response("null"))
    |> should.be_ok
  let receipt = classify.receipt_codec(large_wire(), receipt_questions())
  let saved = codec.encode(receipt, answer) |> should.be_ok
  codec.decode(receipt, saved) |> should.equal(Ok(answer))
  let legacy =
    value.Array([
      value.String("fabric.typesafe.receipt.v1"),
      value.String(answer.request_json),
      value.String(answer.response_json),
    ])
  codec.decode(receipt, legacy) |> should.equal(Ok(answer))
  let bounded = classify.receipt_codec(classify.typesafe(), receipt_questions())
  codec.decode(bounded, saved) |> should.be_error
  codec.decode(bounded, legacy) |> should.be_error
  codec.encode(bounded, answer) |> should.be_error
  let ordinary =
    replay_classification(config(), request(), padded_response("null"))
    |> should.be_ok
  codec.decode(
    bounded,
    value.Array([
      value.String("fabric.typesafe.receipt.v1"),
      value.String(ordinary.request_json),
      value.String(ordinary.response_json),
    ]),
  )
  |> should.equal(Ok(ordinary))
}

pub fn raised_byte_limits_retain_depth_and_element_limits_test() {
  let settings =
    config()
    |> classify.with_request_limit(2_097_152)
    |> classify.with_response_limit(2_097_152)
  let deep =
    list.fold(list.repeat(Nil, 65), value.Null, fn(inner, _) {
      value.Array([inner])
    })
  let wide = value.Array(list.repeat(value.Null, 262_145))
  list.each([deep, wide], fn(state) {
    let bad = classify.request("fixture", state, receipt_questions())
    let failed =
      classify.prepare(large_wire(), settings, bad) |> should.be_error
    let assert error.InvalidRequest(error.InvalidClassificationContent(_)) =
      failed
    let failed =
      replay_classification(
        settings,
        request(),
        padded_response(value.to_string(state)),
      )
      |> should.be_error
    error.kind(failed.error) |> should.equal(error.UnusableResponse)
    failed.sent |> should.equal(llm_wire.Completed)
  })
}

fn padded_response(padding: String) -> String {
  "{\"model\":\"fixture\",\"answers\":{\"correct\":{\"type\":\"noul\",\"noul\":0.9}},\"usage\":{\"input_tokens\":12,\"output_tokens\":8},\"padding\":"
  <> padding
  <> "}"
}

fn replay_classification(
  settings: classify.Config,
  request: classify.Request(question.Noul),
  body: String,
) -> Result(classify.Outcome(question.Noul), llm_wire.Failure) {
  let call = classify.prepare(large_wire(), settings, request) |> should.be_ok
  let http =
    http_testing.playback(
      http_testing.script([
        testing.classification_exchange(
          call,
          testing.classification_response(body),
        ),
      ]),
      http_config.default()
        |> http_config.with_max_buffered_bytes(2_097_152)
        |> http_config.with_max_request_body_bytes(2_097_152),
    )
    |> should.be_ok
  let outcome = classify.run(http, call)
  http_gun.stop(http)
  outcome
}

pub fn incompatible_live_limits_fail_before_revealing_credentials_test() {
  let revealed = process.new_subject()
  let settings =
    classify.config(fn() {
      process.send(revealed, Nil)
      "key"
    })
  list.each(
    [
      settings |> classify.with_request_limit(1_048_577),
      settings |> classify.with_response_limit(1_048_577),
    ],
    fn(settings) {
      classify.prepare(classify.typesafe(), settings, request())
      |> should.be_error
      process.receive(revealed, 0) |> should.be_error
    },
  )
}

fn large_wire() -> classify.Wire {
  classify.typesafe()
  |> classify.with_receipt_request_limit(2_097_152)
  |> classify.with_receipt_response_limit(2_097_152)
}

pub fn live_limits_below_equal_and_above_receipt_bounds_test() {
  let wire =
    classify.typesafe()
    |> classify.with_receipt_request_limit(2048)
    |> classify.with_receipt_response_limit(4096)
  list.each([1024, 2048], fn(request_bytes) {
    list.each([2048, 4096], fn(response_bytes) {
      let settings =
        config()
        |> classify.with_request_limit(request_bytes)
        |> classify.with_response_limit(response_bytes)
      classify.prepare(wire, settings, request()) |> should.be_ok
    })
  })
  let revealed = process.new_subject()
  let settings =
    classify.config(fn() {
      process.send(revealed, Nil)
      "key"
    })
    |> classify.with_request_limit(2048)
    |> classify.with_response_limit(4096)
  list.each(
    [
      #(settings |> classify.with_request_limit(2049), limit.RequestBytes),
      #(settings |> classify.with_response_limit(4097), limit.ResponseBodyBytes),
    ],
    fn(entry) {
      let failed = classify.prepare(wire, entry.0, request()) |> should.be_error
      let assert error.InvalidSetting(error.LimitSetting(kind), _) = failed
      kind |> should.equal(entry.1)
      process.receive(revealed, 0) |> should.be_error
    },
  )
}

pub fn custom_headers_replace_unused_bearer_credentials_test() {
  let settings =
    classify.config(fn() { panic as "unused bearer credential" })
    |> classify.with_headers(fn() { [#("x-custom-token", "custom-secret")] })
  let call =
    classify.prepare(classify.typesafe(), settings, request()) |> should.be_ok
  let exchange = testing.classification_exchange(call, reply())
  let http =
    http_testing.playback(
      http_testing.script([exchange]),
      http_config.default(),
    )
    |> should.be_ok
  classify.run(http, call) |> should.be_ok
  http_gun.stop(http)
  string.contains(string.inspect(settings), "custom-secret") |> should.be_false
  string.contains(string.inspect(call), "custom-secret") |> should.be_false
}

pub fn narrower_live_limits_leave_old_receipt_evidence_readable_test() {
  let wire = large_wire()
  let answer =
    replay_classification(config(), request(), padded_response("null"))
    |> should.be_ok
  let receipt = classify.receipt_codec(wire, receipt_questions())
  let saved = codec.encode(receipt, answer) |> should.be_ok
  let settings =
    classify.config(fn() { panic as "offline receipt touched a secret" })
    |> classify.with_request_limit(1)
    |> classify.with_response_limit(1)
  classify.prepare(wire, settings, request()) |> should.be_error
  codec.decode(receipt, saved) |> should.equal(Ok(answer))
}

pub fn custom_wire_cannot_bypass_response_structure_limits_live_or_stored_test() {
  let decoded = process.new_subject()
  let wire =
    classify.wire(
      message.Custom("extension"),
      "https://extension.example/classify",
      fn(_, _, _) { Ok("{}") },
      fn(_) {
        process.send(decoded, Nil)
        Ok(classify.decoded(
          "extension",
          [#("correct", protocol.Yes(0.9))],
          None,
        ))
      },
    )
  let call = classify.prepare(wire, config(), request()) |> should.be_ok
  let deeply_nested = string.repeat("[", 65) <> "0" <> string.repeat("]", 65)
  list.each([deeply_nested, "{\"number\":1e999999999}", "not JSON"], fn(body) {
    let http =
      http_testing.playback(
        http_testing.script([
          testing.classification_exchange(
            call,
            testing.classification_response(body),
          ),
        ]),
        http_config.default(),
      )
      |> should.be_ok
    let failure = classify.run(http, call) |> should.be_error
    failure.sent |> should.equal(llm_wire.Completed)
    process.receive(decoded, 0) |> should.be_error
    let receipt = classify.receipt_codec(wire, receipt_questions())
    codec.decode(
      receipt,
      value.Array([
        value.String("llm.classification.receipt.v1"),
        value.String("jev-latest"),
        value.String("2 + 2 = 4"),
        value.String("{}"),
        value.String(body),
      ]),
    )
    |> should.be_error
    process.receive(decoded, 0) |> should.be_error
    http_gun.stop(http)
  })
}

pub fn custom_wire_unknown_usage_stays_absent_and_negative_usage_is_rejected_test() {
  list.each([None, Some(message.Usage(-1, 1, 0))], fn(usage) {
    let wire =
      classify.wire(
        message.Custom("extension"),
        "https://extension.example/classify",
        fn(_, _, _) { Ok("{}") },
        fn(_) {
          Ok(classify.decoded(
            "extension",
            [#("correct", protocol.Yes(0.9))],
            usage,
          ))
        },
      )
    let call = classify.prepare(wire, config(), request()) |> should.be_ok
    let http =
      http_testing.playback(
        http_testing.script([
          testing.classification_exchange(
            call,
            testing.classification_response("{}"),
          ),
        ]),
        http_config.default(),
      )
      |> should.be_ok
    case usage {
      None -> {
        let answer = classify.run(http, call) |> should.be_ok
        answer.usage |> should.equal(None)
        let receipt = classify.receipt_codec(wire, receipt_questions())
        let saved = codec.encode(receipt, answer) |> should.be_ok
        codec.decode(receipt, saved) |> should.equal(Ok(answer))
      }
      Some(_) -> classify.run(http, call) |> should.be_error |> fn(_) { Nil }
    }
    http_gun.stop(http)
  })
}

pub fn typesafe_usage_remains_required_and_validated_test() {
  list.each(
    [
      "",
      ",\"usage\":null",
      ",\"usage\":{\"input_tokens\":-1,\"output_tokens\":1}",
      ",\"usage\":{\"input_tokens\":1}",
    ],
    fn(usage) {
      let failed =
        replay_classification(
          config(),
          request(),
          "{\"model\":\"fixture\",\"answers\":{\"correct\":{\"type\":\"noul\",\"noul\":0.9}}"
            <> usage
            <> "}",
        )
        |> should.be_error
      error.kind(failed.error) |> should.equal(error.UnusableResponse)
      failed.sent |> should.equal(llm_wire.Completed)
    },
  )
}
