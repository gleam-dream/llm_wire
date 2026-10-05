import gleam/option.{None}
import gleam/time/duration
import json/blueprint/value
import llm_wire
import llm_wire/classify
import llm_wire/classify/question

pub type Decision {
  Approve
  Revise
}

pub type Answers =
  #(question.Noul, #(question.Choice(Decision), question.Score))

pub fn prepared(reveal: fn() -> String) -> classify.Prepared(Answers) {
  let questions =
    question.combine(
      question.ask(
        "correct",
        question.noul(value.String("Is the statement correct?"), None),
      ),
      question.combine(
        question.ask(
          "decision",
          question.choice(value.String("What should happen?"), [
            question.alternative("approve", Approve, value.String("Correct")),
            question.alternative("revise", Revise, value.String("Incorrect")),
          ]),
        ),
        question.ask(
          "quality",
          question.score(value.String("How correct?"), [
            value.String("incorrect"),
            value.String("partial"),
            value.String("correct"),
          ]),
        ),
      ),
    )
  let config =
    classify.config(reveal)
    |> classify.with_timeout(llm_wire.After(duration.seconds(20)))
  let assert Ok(prepared) =
    classify.prepare(
      classify.typesafe(),
      config,
      classify.request("jev-latest", value.String("2 + 2 = 4"), questions),
    )
  prepared
}
