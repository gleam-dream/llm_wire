import classification_live_scenario
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/cassette
import http_gun/config as http_config
import http_gun/testing as http_testing
import json/blueprint/codec
import json/blueprint/value
import llm_wire
import llm_wire/classify
import llm_wire/classify/question
import llm_wire/error
import llm_wire/internal/classification/runtime
import llm_wire/message
import llm_wire/telemetry
import llm_wire/testing
import sinal
import sinal/correlation

fn config() -> classify.Config {
  classify.typesafe(fn() { "classification-fixture-secret" })
}

fn request() -> classify.Request(question.Noul) {
  classify.request(
    "jev-latest",
    value.String("2 + 2 = 4"),
    question.ask("correct", question.noul(value.String("Is it correct?"), None)),
  )
}

fn prepared() -> classify.Prepared(question.Noul) {
  classify.prepare(config(), request()) |> should.be_ok
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
  answer.usage.total_tokens |> should.equal(20)
  process.receive(seen, 1000) |> should.equal(Ok(telemetry.Started))
  process.receive(seen, 1000) |> should.equal(Ok(telemetry.RequestSent))
  process.receive(seen, 1000) |> should.equal(Ok(telemetry.Terminal))
  process.receive(seen, 1000) |> should.equal(Ok(telemetry.Cleanup))
  let _ = sinal.detach(attachment)
  http_gun.stop(http)
}

pub fn classification_limits_and_timeouts_are_validated_before_dispatch_test() {
  classify.prepare(
    config() |> classify.with_timeout(llm_wire.After(duration.milliseconds(-1))),
    request(),
  )
  |> should.be_error
  classify.prepare(config() |> classify.with_request_limit(1), request())
  |> should.be_error
  classify.prepare(config() |> classify.with_response_limit(0), request())
  |> should.be_error
  classify.prepare(config() |> classify.with_endpoint("not a URL"), request())
  |> should.be_error
  classify.prepare(
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
  let codec = classify.receipt_codec(config(), questions)
  codec.encode(codec, runtime.Outcome(..receipt, usage: message.Usage(0, 0, 0)))
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
