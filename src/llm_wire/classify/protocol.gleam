//// Pure provider extension vocabulary. Native application values stay in the
//// question batch. A wire projects these question views and returns untrusted
//// answer candidates; shared admission validates every candidate.
////
//// Missing concentration evidence is `None`, never an invented measurement.
//// Wires must reject malformed or missing fields required by their protocol.

import gleam/option.{type Option}
import json/blueprint/value.{type Value}

pub type QuestionView {
  YesProbability(instructions: Value, criteria: Option(#(Value, Value)))
  Choice(instructions: Value, alternatives: List(#(String, Value)))
  Score(instructions: Value, levels: List(Value))
}

pub type Answer {
  Yes(yes: Float)
  Selected(
    label: String,
    probabilities: List(#(String, Float)),
    confidence: Option(Float),
  )
  Rated(
    position: Float,
    probabilities: List(#(Int, Float)),
    levels: List(Value),
    confidence: Option(Float),
  )
}
