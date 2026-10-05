//// Typed classification questions and heterogeneous batches.
////
//// Choice labels retain application-native values and the full distribution.
//// Confidence describes provider concentration evidence, not the probability
//// that an answer is correct. Source definitions are total; use `check_*`
//// for definitions assembled from runtime data.

import gleam/option.{type Option}
import gleam/result
import json/blueprint/value.{type Value}
import llm_wire/internal/classification/questions as internal

pub type Noul =
  internal.Noul

pub type Choice(a) =
  internal.Choice(a)

pub type Score =
  internal.Score

pub type Probability(a) =
  internal.Probability(a)

pub type Alternative(a) =
  internal.Alternative(a)

pub type Question(a) =
  internal.Question(a)

pub type Batch(a) =
  internal.Batch(a)

/// One failure boundary for runtime definitions and answer admission.
pub opaque type Error {
  Problem(kind: ErrorKind, detail: String)
}

pub type ErrorKind {
  InvalidDefinition
  InvalidAnswer
}

pub fn error_kind(error: Error) -> ErrorKind {
  error.kind
}

pub fn describe_error(error: Error) -> String {
  error.detail
}

pub fn alternative(
  label: String,
  value: a,
  description: Value,
) -> Alternative(a) {
  internal.alternative(label, value, description)
}

pub fn noul(
  instructions: Value,
  criteria: Option(#(Value, Value)),
) -> Question(Noul) {
  constant(check_noul(instructions, criteria))
}

pub fn check_noul(
  instructions: Value,
  criteria: Option(#(Value, Value)),
) -> Result(Question(Noul), Error) {
  internal.noul(instructions, criteria)
  |> result.map_error(Problem(InvalidDefinition, _))
}

pub fn choice(
  instructions: Value,
  alternatives: List(Alternative(a)),
) -> Question(Choice(a)) {
  constant(check_choice(instructions, alternatives))
}

pub fn check_choice(
  instructions: Value,
  alternatives: List(Alternative(a)),
) -> Result(Question(Choice(a)), Error) {
  internal.choice(instructions, alternatives)
  |> result.map_error(Problem(InvalidDefinition, _))
}

pub fn score(instructions: Value, levels: List(Value)) -> Question(Score) {
  constant(check_score(instructions, levels))
}

pub fn check_score(
  instructions: Value,
  levels: List(Value),
) -> Result(Question(Score), Error) {
  internal.score(instructions, levels)
  |> result.map_error(Problem(InvalidDefinition, _))
}

pub fn ask(id: String, question: Question(a)) -> Batch(a) {
  constant(check_ask(id, question))
}

pub fn check_ask(id: String, question: Question(a)) -> Result(Batch(a), Error) {
  internal.ask(id, question) |> result.map_error(Problem(InvalidDefinition, _))
}

pub fn combine(left: Batch(a), right: Batch(b)) -> Batch(#(a, b)) {
  constant(check_combine(left, right))
}

pub fn check_combine(
  left: Batch(a),
  right: Batch(b),
) -> Result(Batch(#(a, b)), Error) {
  internal.combine(left, right)
  |> result.map_error(Problem(InvalidDefinition, _))
}

/// Provider-neutral question vocabulary; a wire may project it differently.
pub fn definitions(batch: Batch(a)) -> Value {
  internal.definitions(batch)
}

pub fn decode(batch: Batch(a), answers: Value) -> Result(a, Error) {
  internal.decode(batch, answers) |> result.map_error(Problem(InvalidAnswer, _))
}

fn constant(value: Result(a, Error)) -> a {
  case value {
    Ok(value) -> value
    Error(error) -> panic as describe_error(error)
  }
}
