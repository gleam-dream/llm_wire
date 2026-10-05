import gleam/list
import gleam/option.{None}
import gleam/result
import gleeunit/should
import json/blueprint/value
import llm_wire/classify/question
import llm_wire/internal/classification/typesafe
import llm_wire/internal/classification/wire

type Decision {
  Approve
  Revise
}

pub fn typed_batch_preserves_boolean_choice_and_rubric_evidence_test() {
  let assert Ok(noul) =
    question.check_noul(value.String("Is the arithmetic correct?"), None)
  let assert Ok(choice) =
    question.check_choice(value.String("What should happen?"), [
      question.alternative("approve", Approve, value.String("Correct")),
      question.alternative("revise", Revise, value.String("Incorrect")),
    ])
  let levels = [
    value.String("incorrect"),
    value.String("partial"),
    value.String("correct"),
  ]
  let assert Ok(score) =
    question.check_score(value.String("How correct is the statement?"), levels)
  let assert Ok(first) = question.check_ask("correct", noul)
  let assert Ok(second) = question.check_ask("decision", choice)
  let assert Ok(third) = question.check_ask("quality", score)
  let assert Ok(combined) = question.check_combine(second, third)
  let assert Ok(batch) = question.check_combine(first, combined)
  let answers =
    json(
      "{\"correct\":{\"type\":\"noul\",\"noul\":0.8},\"decision\":{\"type\":\"choice\",\"choice\":\"approve\",\"probabilities\":{\"revise\":0.2,\"approve\":0.8},\"confidence\":0.7},\"quality\":{\"type\":\"score\",\"score\":1.8,\"probabilities\":{\"0\":0.0,\"1\":0.2,\"2\":0.8},\"legend\":{\"0\":\"incorrect\",\"1\":\"partial\",\"2\":\"correct\"},\"confidence\":0.7}}",
    )
  let assert Ok(#(yes, #(decision, rating))) = decode(batch, answers)
  yes.yes |> should.equal(0.8)
  decision.selected |> should.equal(Approve)
  decision.label |> should.equal("approve")
  decision.probabilities
  |> list.map(fn(p) { #(p.label, p.value, p.probability) })
  |> should.equal([#("approve", Approve, 0.8), #("revise", Revise, 0.2)])
  rating.position |> should.equal(1.8)
  rating.levels |> should.equal(levels)
  rating.probabilities |> should.equal([#(0, 0.0), #(1, 0.2), #(2, 0.8)])
}

fn json(raw: String) -> value.Value {
  let assert Ok(value) = value.parse(raw, value.default_limits())
  value
}

pub fn invalid_question_definitions_are_rejected_before_network_work_test() {
  question.check_noul(value.Bool(True), None) |> should.be_error
  question.check_noul(
    value.Object([#("a", value.Null), #("a", value.Null)]),
    None,
  )
  |> should.be_error
  question.check_choice(value.String("choose"), []) |> should.be_error
  question.check_choice(value.String("choose"), [
    question.alternative("same", Approve, value.Null),
    question.alternative("same", Revise, value.Null),
  ])
  |> should.be_error
  question.check_score(value.String("score"), [value.String("only")])
  |> should.be_error
  question.check_score(
    value.String("score"),
    list.repeat(value.String("level"), 11),
  )
  |> should.be_error
  let assert Ok(noul) = question.check_noul(value.String("yes?"), None)
  question.check_ask("", noul) |> should.be_error
  let assert Ok(batch) = question.check_ask("answer", noul)
  question.check_combine(batch, batch) |> should.be_error
}

pub fn a_probability_is_checked_before_float_rounding_and_underflow_test() {
  let assert Ok(noul) = question.check_noul(value.String("yes?"), None)
  let assert Ok(batch) = question.check_ask("answer", noul)
  list.each(
    ["1.00000000000000001", "-0.00000000000000001", "1e-500", "2", "\"0.8\""],
    fn(raw) {
      decode(
        batch,
        json("{\"answer\":{\"type\":\"noul\",\"noul\":" <> raw <> "}}"),
      )
      |> should.be_error
    },
  )
  decode(batch, json("{\"answer\":{\"type\":\"noul\",\"noul\":1}}"))
  |> should.be_ok
  |> fn(answer) { answer.yes }
  |> should.equal(1.0)
  decode(batch, json("{\"answer\":{\"type\":\"noul\",\"noul\":0}}"))
  |> should.be_ok
  |> fn(answer) { answer.yes }
  |> should.equal(0.0)
}

pub fn unknown_incomplete_and_inconsistent_choice_evidence_is_rejected_test() {
  let assert Ok(choice) =
    question.check_choice(value.String("choose"), [
      question.alternative("approve", Approve, value.Null),
      question.alternative("revise", Revise, value.Null),
    ])
  let assert Ok(batch) = question.check_ask("decision", choice)
  list.each(
    [
      "{\"type\":\"noul\",\"noul\":0.5}",
      "{\"type\":\"choice\",\"choice\":\"approve\",\"probabilities\":{\"approve\":1},\"confidence\":1}",
      "{\"type\":\"choice\",\"choice\":\"other\",\"probabilities\":{\"approve\":0.8,\"revise\":0.2},\"confidence\":0.7}",
      "{\"type\":\"choice\",\"choice\":\"revise\",\"probabilities\":{\"approve\":0.8,\"revise\":0.2},\"confidence\":0.7}",
      "{\"type\":\"choice\",\"choice\":\"approve\",\"probabilities\":{\"approve\":0.8,\"revise\":0.1},\"confidence\":0.7}",
      "{\"type\":\"choice\",\"choice\":\"approve\",\"probabilities\":{\"approve\":0.8,\"revise\":0.2},\"confidence\":1.1}",
    ],
    fn(answer) {
      decode(batch, json("{\"decision\":" <> answer <> "}"))
      |> should.be_error
    },
  )
  decode(batch, json("{}")) |> should.be_error
  decode(
    batch,
    value.Object([#("decision", value.Null), #("decision", value.Null)]),
  )
  |> should.be_error
}

pub fn a_score_cannot_change_the_rubric_or_disagree_with_its_distribution_test() {
  let assert Ok(score) =
    question.check_score(value.String("rate"), [
      value.String("low"),
      value.String("middle"),
      value.String("high"),
    ])
  let assert Ok(batch) = question.check_ask("rating", score)
  list.each(
    [
      "{\"type\":\"score\",\"score\":0.5,\"probabilities\":{\"0\":0,\"1\":0.5,\"2\":0.5},\"legend\":{\"0\":\"low\",\"1\":\"middle\",\"2\":\"high\"},\"confidence\":0.1}",
      "{\"type\":\"score\",\"score\":1.5,\"probabilities\":{\"0\":0,\"1\":0.5,\"2\":0.5},\"legend\":{\"0\":\"high\",\"1\":\"middle\",\"2\":\"low\"},\"confidence\":0.1}",
      "{\"type\":\"score\",\"score\":3,\"probabilities\":{\"0\":0,\"1\":0,\"2\":1},\"legend\":{\"0\":\"low\",\"1\":\"middle\",\"2\":\"high\"},\"confidence\":1}",
    ],
    fn(answer) {
      decode(batch, json("{\"rating\":" <> answer <> "}"))
      |> should.be_error
    },
  )
}

fn decode(batch: question.Batch(a), raw: value.Value) -> Result(a, wire.Error) {
  use candidates <- result.try(typesafe.decode_answers(raw))
  question.decode(batch, candidates)
  |> result.map_error(fn(e) { wire.InvalidValue(question.describe_error(e)) })
}
