//// External acceptance of the classification family and another wire.

import gleam/time/duration
import http_gun
import http_gun/config as http_config
import http_gun/testing as http_testing
import json/blueprint/codec
import json/blueprint/value
import llm_wire
import llm_wire/classify
import llm_wire/classify/question
import llm_wire/error
import llm_wire/message
import llm_wire/testing

type Label {
  Publish
  Revise
}

pub fn main() -> Nil {
  let questions =
    question.ask(
      "decision",
      question.choice(value.String("What next?"), [
        question.alternative("publish", Publish, value.Null),
        question.alternative("revise", Revise, value.Null),
      ]),
    )
  let settings =
    classify.typesafe(fn() { "consumer-secret" })
    |> classify.with_timeout(llm_wire.After(duration.seconds(20)))
    |> classify.with_response_limit(4096)
  let request = classify.request("fixture", value.String("draft"), questions)
  let assert Ok(prepared) = classify.prepare(settings, request)
  let raw =
    "{\"model\":\"fixture\",\"answers\":{\"decision\":{\"type\":\"choice\",\"choice\":\"publish\",\"probabilities\":{\"publish\":0.8,\"revise\":0.2},\"confidence\":0.7}},\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}"
  let tape =
    http_testing.script([
      testing.classification_exchange(
        prepared,
        testing.classification_response(raw),
      ),
    ])
  let assert Ok(http) = http_testing.playback(tape, http_config.default())
  let assert Ok(answer) = classify.run(http, prepared)
  let assert Publish = answer.answer.selected
  let assert 2 = answer.usage.input_tokens
  let codec = classify.receipt_codec(settings, questions)
  let assert Ok(saved) = codec.encode_json(codec, answer)
  let assert Ok(restored) = codec.decode_json(codec, saved)
  let assert True = restored == answer
  let assert Error(failed) = classify.run(http, prepared)
  let assert llm_wire.NotSent = failed.sent
  let assert error.Transport = error.kind(failed.error)
  http_gun.stop(http)
  // A second wire uses a different envelope and never imports internals.
  let wire =
    classify.wire(
      message.Custom("other"),
      "https://other.example/classify",
      fn() { [] },
      fn(model, state, questions) {
        Ok(
          value.to_string(
            value.Object([
              #("engine", value.String(model)),
              #("input", state),
              #("tasks", questions),
            ]),
          ),
        )
      },
      fn(_) {
        let assert Ok(answers) =
          value.parse(
            "{\"decision\":{\"type\":\"choice\",\"choice\":\"revise\",\"probabilities\":{\"publish\":0.0,\"revise\":1.0},\"confidence\":1.0}}",
            value.default_limits(),
          )
        Ok(classify.decoded("other-model", answers, message.Usage(1, 1, 2)))
      },
    )
  let settings = classify.config(wire)
  let assert Ok(prepared) = classify.prepare(settings, request)
  let tape =
    http_testing.script([
      testing.classification_exchange(
        prepared,
        testing.classification_response("other envelope"),
      ),
    ])
  let assert Ok(http) = http_testing.playback(tape, http_config.default())
  let assert Ok(answer) = classify.run(http, prepared)
  let assert Revise = answer.answer.selected
  let codec = classify.receipt_codec(settings, questions)
  let assert Ok(saved) = codec.encode_json(codec, answer)
  let assert Ok(restored) = codec.decode_json(codec, saved)
  let assert True = restored == answer
  http_gun.stop(http)
  let assert Error(problem) = question.check_choice(value.String("invalid"), [])
  let assert question.InvalidDefinition = question.error_kind(problem)
  Nil
}
