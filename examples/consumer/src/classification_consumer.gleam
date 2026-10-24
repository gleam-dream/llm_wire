//// External acceptance using only public imports and a different JSON protocol.

import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration
import http_gun
import http_gun/config as http_config
import http_gun/testing as http_testing
import json/blueprint/codec
import json/blueprint/value
import llm_wire
import llm_wire/classify
import llm_wire/classify/protocol
import llm_wire/classify/question
import llm_wire/error
import llm_wire/message
import llm_wire/testing

type Label {
  Publish
  Revise
}

pub fn main() -> Nil {
  let choice =
    question.ask(
      "decision",
      question.choice(value.String("What next?"), [
        question.alternative("publish", Publish, value.Null),
        question.alternative("revise", Revise, value.Null),
      ]),
    )
  let settings =
    classify.config(fn() { "consumer-secret" })
    |> classify.with_timeout(llm_wire.After(duration.seconds(20)))
    |> classify.with_response_limit(4096)
  let request = classify.request("fixture", value.String("draft"), choice)
  let assert Ok(prepared) =
    classify.prepare(classify.typesafe(), settings, request)
  let raw =
    "{\"model\":\"fixture\",\"answers\":{\"decision\":{\"type\":\"choice\",\"choice\":\"publish\",\"probabilities\":{\"publish\":0.8,\"revise\":0.2},\"confidence\":0.7}},\"usage\":{\"input_tokens\":2,\"output_tokens\":1}}"
  let http = replay(prepared, raw)
  let assert Ok(answer) = classify.run(http, prepared)
  let assert Publish = answer.answer.selected
  let assert Some(usage) = answer.usage
  let assert 2 = usage.input_tokens
  let assert Some(0.7) = answer.answer.confidence
  let receipt = classify.receipt_codec(classify.typesafe(), choice)
  let assert Ok(saved) = codec.encode_json(receipt, answer)
  let assert Ok(restored) = codec.decode_json(receipt, saved)
  let assert True = restored == answer
  let assert Error(failed) = classify.run(http, prepared)
  let assert llm_wire.NotSent = failed.sent
  let assert error.Transport = error.kind(failed.error)
  http_gun.stop(http)

  // The wire gets typed views; its JSON uses arrays and no TypeSafe field names.
  let wire =
    classify.wire(
      message.Custom("other"),
      "https://other.example/classify",
      encode,
      decode,
    )
  let unsupported =
    question.ask(
      "rating",
      question.score(value.String("Rate"), [
        value.String("low"),
        value.String("high"),
      ]),
    )
  let no_credentials =
    classify.config(fn() { panic as "unsupported question accessed credentials" })
  let assert Error(error.InvalidRequest(error.ClassificationQuestionUnsupported(
    "rating",
  ))) =
    classify.prepare(
      wire,
      no_credentials,
      classify.request("other-model", value.String("draft"), unsupported),
    )
  let questions =
    question.combine(
      choice,
      question.ask("valid", question.noul(value.String("Is valid?"), None)),
    )
  let request =
    classify.request("other-model", value.String("draft"), questions)
  let settings =
    settings
    |> classify.with_endpoint("https://other.example/custom")
    |> classify.with_headers(fn() {
      [#("x-api-token", "consumer-custom-secret")]
    })
  let assert Ok(prepared) = classify.prepare(wire, settings, request)
  let raw =
    "[\"other-model\",[[[\"decision\",[\"revise\",[[\"publish\",0.0],[\"revise\",1.0]]]]],[[\"valid\",0.8]]]]"
  let http = replay(prepared, raw)
  let assert Ok(answer) = classify.run(http, prepared)
  let #(decision, valid) = answer.answer
  let assert Revise = decision.selected
  let assert None = decision.confidence
  let assert None = answer.usage
  let assert 0.8 = valid.yes
  let receipt = classify.receipt_codec(wire, questions)
  let assert Ok(saved) = codec.encode_json(receipt, answer)
  let assert Ok(restored) = codec.decode_json(receipt, saved)
  let assert True = restored == answer
  http_gun.stop(http)

  let malformed =
    "[\"other-model\",[[[\"decision\",[\"revise\",[[\"publish\",1.0],[\"revise\",1.0]]]]],[[\"valid\",0.8]]]]"
  let http = replay(prepared, malformed)
  let assert Error(failure) = classify.run(http, prepared)
  let assert error.UnusableResponse = error.kind(failure.error)
  http_gun.stop(http)
  let assert Error(problem) = question.check_choice(value.String("invalid"), [])
  let assert question.InvalidDefinition = question.error_kind(problem)
  Nil
}

fn replay(prepared: classify.Prepared(a), raw: String) -> http_gun.Client {
  let assert Ok(http) =
    http_testing.playback(
      http_testing.script([
        testing.classification_exchange(
          prepared,
          testing.classification_response(raw),
        ),
      ]),
      http_config.default(),
    )
  http
}

fn encode(
  model: String,
  state: value.Value,
  questions: List(#(String, protocol.QuestionView)),
) -> Result(String, error.PrepareError) {
  use tasks <- result.map(
    list.try_map(questions, fn(q) {
      use view <- result.map(case q.1 {
        protocol.YesProbability(instructions, criteria) ->
          Ok(
            value.Array([
              value.String("boolean"),
              instructions,
              case criteria {
                None -> value.Null
                Some(#(yes, no)) -> value.Array([yes, no])
              },
            ]),
          )
        protocol.Choice(instructions, alternatives) ->
          Ok(
            value.Array([
              value.String("select"),
              instructions,
              value.Array(
                list.map(alternatives, fn(a) {
                  value.Array([value.String(a.0), a.1])
                }),
              ),
            ]),
          )
        protocol.Score(_, _) ->
          Error(
            error.InvalidRequest(error.ClassificationQuestionUnsupported(q.0)),
          )
      })
      value.Array([value.String(q.0), view])
    }),
  )
  value.to_string(value.Array([value.String(model), state, value.Array(tasks)]))
}

fn decode(raw: String) -> Result(classify.Decoded, error.Error) {
  let distribution = codec.list(codec.pair(codec.string(), codec.float()))
  let choices =
    codec.list(codec.pair(
      codec.string(),
      codec.pair(codec.string(), distribution),
    ))
  let yes = codec.list(codec.pair(codec.string(), codec.float()))
  let response = codec.pair(codec.string(), codec.pair(choices, yes))
  use #(model, #(choices, yes)) <- result.map(
    codec.decode_json(response, raw)
    |> result.replace_error(error.Protocol("invalid other-provider response")),
  )
  let candidates =
    list.append(
      list.map(choices, fn(c) { #(c.0, protocol.Selected(c.1.0, c.1.1, None)) }),
      list.map(yes, fn(c) { #(c.0, protocol.Yes(c.1)) }),
    )
  classify.decoded(model, candidates, None)
}
