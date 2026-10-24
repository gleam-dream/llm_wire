import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import json/blueprint/value
import llm_wire/classify/protocol
import llm_wire/classify/question
import llm_wire/internal/classification/typesafe

type Label {
  Accept
  Reject
}

fn choices() -> question.Batch(question.Choice(Label)) {
  question.ask(
    "route",
    question.choice(value.String("Choose"), [
      question.alternative("accept", Accept, value.Null),
      question.alternative("reject", Reject, value.Null),
    ]),
  )
}

pub fn typed_candidates_preserve_native_values_and_absent_confidence_test() {
  let levels = [value.String("low"), value.String("high")]
  let questions =
    question.combine(
      choices(),
      question.combine(
        question.ask("yes", question.noul(value.String("Yes?"), None)),
        question.ask("score", question.score(value.String("Score"), levels)),
      ),
    )
  let candidates = [
    #(
      "route",
      protocol.Selected("accept", [#("reject", 0.25), #("accept", 0.75)], None),
    ),
    #("yes", protocol.Yes(0.8)),
    #("score", protocol.Rated(0.75, [#(1, 0.75), #(0, 0.25)], levels, None)),
  ]
  let assert Ok(#(choice, #(yes, score))) =
    question.decode(questions, candidates)
  choice.selected |> should.equal(Accept)
  choice.confidence |> should.equal(None)
  choice.probabilities
  |> list.map(fn(p) { #(p.label, p.value, p.probability) })
  |> should.equal([#("accept", Accept, 0.75), #("reject", Reject, 0.25)])
  score.confidence |> should.equal(None)
  score.probabilities |> should.equal([#(0, 0.25), #(1, 0.75)])
  yes.yes |> should.equal(0.8)
}

pub fn typed_choice_candidates_cannot_bypass_shared_admission_test() {
  let probabilities = [#("accept", 0.75), #("reject", 0.25)]
  list.each(
    [
      protocol.Yes(0.7),
      protocol.Selected("accept", [#("accept", 0.5), #("accept", 0.5)], None),
      protocol.Selected("accept", [#("accept", 1.0)], None),
      protocol.Selected("unknown", probabilities, None),
      protocol.Selected("reject", probabilities, None),
      protocol.Selected("accept", [#("accept", 0.7), #("reject", 0.1)], None),
      protocol.Selected("accept", [#("accept", 1.1), #("reject", -0.1)], None),
      protocol.Selected("accept", probabilities, Some(-0.1)),
      protocol.Selected("accept", probabilities, Some(1.1)),
    ],
    fn(answer) {
      question.decode(choices(), [#("route", answer)]) |> should.be_error
    },
  )
  let answer = protocol.Selected("accept", probabilities, Some(0.5))
  question.decode(choices(), [#("route", answer), #("route", answer)])
  |> should.be_error
  let questions =
    question.combine(
      choices(),
      question.ask("yes", question.noul(value.String("Yes?"), None)),
    )
  question.decode(questions, [#("route", answer), #("route", answer)])
  |> should.be_error
  question.decode(choices(), [#("other", answer)]) |> should.be_error
  question.decode(choices(), [#("route", answer)])
  |> should.be_ok
  |> fn(choice) { choice.confidence }
  |> should.equal(Some(0.5))
}

pub fn typed_score_candidates_cannot_change_rubric_or_position_test() {
  let levels = [value.String("low"), value.String("high")]
  let questions =
    question.ask("score", question.score(value.String("Score"), levels))
  list.each(
    [
      protocol.Rated(0.8, [#(0, 0.25), #(1, 0.75)], levels, None),
      protocol.Rated(0.75, [#(0, 0.25), #(1, 0.75)], list.reverse(levels), None),
      protocol.Rated(0.75, [#(1, 0.5), #(1, 0.5)], levels, None),
      protocol.Rated(1.5, [#(0, 0.0), #(1, 1.0)], levels, None),
      protocol.Rated(0.75, [#(0, 0.25), #(1, 0.75)], levels, Some(1.1)),
    ],
    fn(answer) {
      question.decode(questions, [#("score", answer)]) |> should.be_error
    },
  )
}

pub fn typesafe_missing_or_malformed_confidence_is_not_absence_test() {
  list.each(
    [
      "",
      ",\"confidence\":null",
      ",\"confidence\":\"high\"",
      ",\"confidence\":1.1",
    ],
    fn(confidence) {
      let assert Ok(raw) =
        value.parse(
          "{\"route\":{\"type\":\"choice\",\"choice\":\"accept\",\"probabilities\":{\"accept\":0.75,\"reject\":0.25}"
            <> confidence
            <> "}}",
          value.default_limits(),
        )
      typesafe.decode_answers(raw) |> should.be_error
    },
  )
}
