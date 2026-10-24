//// The representation behind `llm_wire/classify/question.Question` and
//// `llm_wire/classify/question.Batch`. Each carries a placeholder answer of
//// its type, which the receipt codec needs and which is never a real answer.

import llm_wire/classify/protocol.{type Answer, type QuestionView}
import llm_wire/internal/classification/wire

pub opaque type Question(a) {
  Question(
    definition: QuestionView,
    decode: fn(Answer) -> Result(a, wire.Error),
    placeholder: a,
  )
}

pub opaque type Batch(a) {
  Batch(
    definitions: List(#(String, QuestionView)),
    decode: fn(List(#(String, Answer))) -> Result(a, wire.Error),
    placeholder: a,
  )
}

pub fn question(
  definition: QuestionView,
  decode: fn(Answer) -> Result(a, wire.Error),
  placeholder: a,
) -> Question(a) {
  Question(definition:, decode:, placeholder:)
}

pub fn question_definition(question: Question(a)) -> QuestionView {
  question.definition
}

pub fn question_decode(
  question: Question(a),
) -> fn(Answer) -> Result(a, wire.Error) {
  question.decode
}

pub fn question_placeholder(question: Question(a)) -> a {
  question.placeholder
}

pub fn batch(
  definitions: List(#(String, QuestionView)),
  decode: fn(List(#(String, Answer))) -> Result(a, wire.Error),
  placeholder: a,
) -> Batch(a) {
  Batch(definitions:, decode:, placeholder:)
}

pub fn definitions(batch: Batch(a)) -> List(#(String, QuestionView)) {
  batch.definitions
}

pub fn decode(
  batch: Batch(a),
) -> fn(List(#(String, Answer))) -> Result(a, wire.Error) {
  batch.decode
}

/// An answer of the batch's type, for a codec that needs one.
pub fn placeholder(batch: Batch(a)) -> a {
  batch.placeholder
}
