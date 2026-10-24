//// Typed classification questions, independent of providers and graph scheduling.

import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import json/blueprint/value.{type Value}
import llm_wire/classify/protocol
import llm_wire/internal/classification/batch as internal
import llm_wire/internal/classification/wire

pub type Noul {
  Noul(yes: Float)
}

pub opaque type Alternative(a) {
  Alternative(label: String, value: a, description: Value)
}

pub type Probability(a) {
  Probability(label: String, value: a, probability: Float)
}

pub type Choice(a) {
  Choice(
    selected: a,
    label: String,
    probabilities: List(Probability(a)),
    confidence: Option(Float),
  )
}

pub type Score {
  Score(
    position: Float,
    probabilities: List(#(Int, Float)),
    confidence: Option(Float),
    levels: List(Value),
  )
}

/// One typed question. Build one with `noul`, `choice` or `score`.
pub type Question(a) =
  internal.Question(a)

/// Named questions asked together, decoded into one typed answer. Build one
/// with `ask` and `combine`.
pub type Batch(a) =
  internal.Batch(a)

/// Keep a yes probability until application routing chooses its own threshold.
pub fn noul(
  instructions: Value,
  criteria: Option(#(Value, Value)),
) -> Result(Question(Noul), wire.Error) {
  use instructions <- result.try(wire.content(instructions))
  use criteria <- result.try(case criteria {
    None -> Ok(None)
    Some(#(yes, no)) -> {
      use yes <- result.try(wire.content(yes))
      use no <- result.map(wire.content(no))
      Some(#(yes, no))
    }
  })
  Ok(internal.question(
    protocol.YesProbability(instructions, criteria),
    fn(raw) {
      case raw {
        protocol.Yes(yes) -> checked_number(yes, 0.0, 1.0) |> result.map(Noul)
        _ ->
          Error(wire.InvalidValue(
            "classifier answer kind differs from its question",
          ))
      }
    },
    Noul(0.0),
  ))
}

/// Labels map to application-native values. The original labels and complete
/// distribution remain available even when several labels map to the same value.
pub fn choice(
  instructions: Value,
  alternatives: List(Alternative(a)),
) -> Result(Question(Choice(a)), wire.Error) {
  use instructions <- result.try(wire.content(instructions))
  use Nil <- result.try(wire.require(
    list.length(alternatives) >= 2 && list.length(alternatives) <= 255,
    "a Choice requires 2–255 options",
  ))
  use criteria <- result.try(
    list.try_map(alternatives, fn(alternative) {
      use Nil <- result.try(wire.require(
        string.trim(alternative.label) != "",
        "empty Choice label",
      ))
      use description <- result.map(case alternative.description {
        value.Null -> Ok(value.Null)
        other -> wire.content(other)
      })
      #(alternative.label, description)
    }),
  )
  use _ <- result.try(
    value.object(criteria)
    |> result.map_error(fn(_) { wire.InvalidValue("duplicate Choice label") }),
  )
  let labels =
    list.map(alternatives, fn(option) { #(option.label, option.value) })
  use first <- result.try(
    list.first(alternatives)
    |> result.replace_error(wire.InvalidValue("a Choice requires 2–255 options")),
  )
  Ok(internal.question(
    protocol.Choice(instructions, criteria),
    fn(raw) {
      use #(selected, probabilities, confidence) <- result.try(case raw {
        protocol.Selected(selected, probabilities, confidence) ->
          Ok(#(selected, probabilities, confidence))
        _ ->
          Error(wire.InvalidValue(
            "classifier answer kind differs from its question",
          ))
      })
      use selected_value <- result.try(
        list.key_find(labels, selected)
        |> result.map_error(fn(_) {
          wire.InvalidValue("unknown selected Choice label")
        }),
      )
      use probabilities <- result.try(distribution(
        probabilities,
        wire.keys(labels),
      ))
      use selected_probability <- result.try(
        list.key_find(probabilities, selected)
        |> result.map_error(fn(_) {
          wire.InvalidValue("missing selected Choice probability")
        }),
      )
      use Nil <- result.try(wire.require(
        list.all(probabilities, fn(p) {
          p.1 <=. selected_probability +. 0.00001
        }),
        "selected Choice label is not maximal",
      ))
      use confidence <- result.try(check_confidence(confidence))
      use typed <- result.map(
        list.try_map(labels, fn(label) {
          use probability <- result.map(
            list.key_find(probabilities, label.0)
            |> result.map_error(fn(_) {
              wire.InvalidValue("missing Choice probability")
            }),
          )
          Probability(label.0, label.1, probability)
        }),
      )
      Choice(selected_value, selected, typed, confidence)
    },
    Choice(first.value, first.label, [], None),
  ))
}

/// The position belongs to the authored rubric, from 0 through levels - 1.
pub fn score(
  instructions: Value,
  levels: List(Value),
) -> Result(Question(Score), wire.Error) {
  use instructions <- result.try(wire.content(instructions))
  use Nil <- result.try(wire.require(
    list.length(levels) >= 2 && list.length(levels) <= 10,
    "a Score requires 2–10 levels",
  ))
  use levels <- result.try(list.try_map(levels, wire.content))
  let indices = list.index_map(levels, fn(_, index) { index })
  Ok(internal.question(
    protocol.Score(instructions, levels),
    fn(raw) {
      use #(position, probabilities, returned_levels, confidence) <- result.try(
        case raw {
          protocol.Rated(position, probabilities, levels, confidence) ->
            Ok(#(position, probabilities, levels, confidence))
          _ ->
            Error(wire.InvalidValue(
              "classifier answer kind differs from its question",
            ))
        },
      )
      use Nil <- result.try(wire.require(
        list.map(returned_levels, wire.canonical)
          == list.map(levels, wire.canonical),
        "Score legend differs from the sent rubric",
      ))
      use probabilities <- result.try(distribution(probabilities, indices))
      use position <- result.try(checked_number(
        position,
        0.0,
        int.to_float(list.length(levels) - 1),
      ))
      // The distribution is in rubric order after admission.
      let indexed =
        list.index_map(probabilities, fn(p, index) { #(index, p.1) })
      let expected =
        list.fold(indexed, 0.0, fn(total, p) {
          total +. int.to_float(p.0) *. p.1
        })
      use Nil <- result.try(wire.require(
        float.absolute_value(position -. expected)
          <=. 0.00001 *. int.to_float(list.length(levels)),
        "Score disagrees with its distribution",
      ))
      use confidence <- result.map(check_confidence(confidence))
      Score(position, indexed, confidence, levels)
    },
    Score(0.0, [], None, levels),
  ))
}

pub fn ask(id: String, question: Question(a)) -> Result(Batch(a), wire.Error) {
  use Nil <- result.map(wire.require(
    string.trim(id) != "",
    "empty classifier question ID",
  ))
  let decode = internal.question_decode(question)
  internal.batch(
    [#(id, internal.question_definition(question))],
    fn(fields) {
      list.key_find(fields, id)
      |> result.replace_error(wire.MissingField(id))
      |> result.try(decode)
    },
    internal.question_placeholder(question),
  )
}

/// Independent questions share one state and HTTP request, with native answers.
pub fn combine(
  left: Batch(a),
  right: Batch(b),
) -> Result(Batch(#(a, b)), wire.Error) {
  let entries =
    list.append(internal.definitions(left), internal.definitions(right))
  use Nil <- result.try(wire.require(
    list.length(entries) <= 256,
    "classifier question count exceeds 256",
  ))
  use Nil <- result.try(wire.require(
    list.length(list.unique(wire.keys(entries))) == list.length(entries),
    "duplicate classifier question ID",
  ))
  let decode_left = internal.decode(left)
  let decode_right = internal.decode(right)
  Ok(
    internal.batch(
      entries,
      fn(fields) {
        use left <- result.try(decode_left(fields))
        use right <- result.map(decode_right(fields))
        #(left, right)
      },
      #(internal.placeholder(left), internal.placeholder(right)),
    ),
  )
}

pub fn definitions(batch: Batch(a)) -> List(#(String, protocol.QuestionView)) {
  internal.definitions(batch)
}

pub fn decode(
  batch: Batch(a),
  answers: List(#(String, protocol.Answer)),
) -> Result(a, wire.Error) {
  use Nil <- result.try(wire.require(
    wire.same_keys(answers, wire.keys(internal.definitions(batch))),
    "classifier answer IDs do not match its questions",
  ))
  internal.decode(batch)(answers)
}

fn checked_number(
  n: Float,
  minimum: Float,
  maximum: Float,
) -> Result(Float, wire.Error) {
  use Nil <- result.map(wire.require(
    n >=. minimum && n <=. maximum,
    "classifier number is outside its valid range",
  ))
  n
}

fn check_confidence(
  confidence: Option(Float),
) -> Result(Option(Float), wire.Error) {
  case confidence {
    None -> Ok(None)
    Some(n) -> checked_number(n, 0.0, 1.0) |> result.map(Some)
  }
}

fn distribution(
  fields: List(#(label, Float)),
  labels: List(label),
) -> Result(List(#(label, Float)), wire.Error) {
  use Nil <- result.try(wire.require(
    list.length(fields) == list.length(labels)
      && list.length(list.unique(list.map(fields, fn(p) { p.0 })))
      == list.length(labels)
      && list.all(fields, fn(p) { list.contains(labels, p.0) }),
    "classifier probability labels do not match criteria",
  ))
  use probabilities <- result.try(
    list.try_map(labels, fn(label) {
      use p <- result.try(
        list.key_find(fields, label)
        |> result.replace_error(wire.InvalidValue(
          "missing classifier probability",
        )),
      )
      use p <- result.map(checked_number(p, 0.0, 1.0))
      #(label, p)
    }),
  )
  let sum = list.fold(probabilities, 0.0, fn(total, p) { total +. p.1 })
  use Nil <- result.map(wire.require(
    float.absolute_value(sum -. 1.0) <=. 0.00001,
    "classifier probabilities do not sum to one",
  ))
  probabilities
}

pub fn alternative(
  label: String,
  value: a,
  description: Value,
) -> Alternative(a) {
  Alternative(label, value, description)
}
