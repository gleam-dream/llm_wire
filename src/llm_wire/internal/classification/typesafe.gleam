import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import json/blueprint/value
import llm_wire/classify/protocol
import llm_wire/error
import llm_wire/internal/classification/runtime
import llm_wire/internal/classification/wire
import llm_wire/message

pub fn wire() -> runtime.Wire {
  runtime.wire(
    message.Custom("typesafe"),
    "https://api.typesafe.ai/v1/systemone",
    encode,
    decode,
  )
}

fn definition(question: protocol.QuestionView) -> value.Value {
  case question {
    protocol.YesProbability(instructions, criteria) -> {
      let criteria = case criteria {
        None -> []
        Some(#(yes, no)) -> [
          #("criteria", value.Object([#("true", yes), #("false", no)])),
        ]
      }
      value.Object([
        #("type", value.String("noul")),
        #("instructions", instructions),
        ..criteria
      ])
    }
    protocol.Choice(instructions, alternatives) ->
      value.Object([
        #("type", value.String("choice")),
        #("instructions", instructions),
        #("criteria", value.Object(alternatives)),
      ])
    protocol.Score(instructions, levels) ->
      value.Object([
        #("type", value.String("score")),
        #("instructions", instructions),
        #("criteria", value.Array(levels)),
      ])
  }
}

fn encode(
  model: String,
  state: value.Value,
  questions: List(#(String, protocol.QuestionView)),
) -> Result(String, error.PrepareError) {
  use state <- result.map(
    wire.content(state)
    |> result.map_error(fn(detail) {
      error.InvalidRequest(
        error.InvalidClassificationContent(wire.describe_error(detail)),
      )
    }),
  )
  value.to_string(
    value.Object([
      #("model", value.String(model)),
      #("state", state),
      #(
        "questions",
        value.Object(list.map(questions, fn(q) { #(q.0, definition(q.1)) })),
      ),
    ]),
  )
}

fn decode(raw: String) -> Result(runtime.Decoded, error.Error) {
  decode_response(raw)
  |> result.map_error(fn(problem) {
    error.Protocol(wire.describe_error(problem))
  })
}

fn decode_response(raw: String) -> Result(runtime.Decoded, wire.Error) {
  use fields <- result.try(wire.parse(raw) |> result.try(wire.object))
  use model <- result.try(
    wire.required(fields, "model") |> result.try(wire.text),
  )
  use answers <- result.try(
    wire.required(fields, "answers") |> result.try(decode_answers),
  )
  use usage <- result.try(
    wire.required(fields, "usage") |> result.try(wire.object),
  )
  use input <- result.try(
    wire.required(usage, "input_tokens") |> result.try(wire.integer),
  )
  use output <- result.try(
    wire.required(usage, "output_tokens") |> result.try(wire.integer),
  )
  use Nil <- result.map(wire.require(
    input >= 0 && output >= 0,
    "negative classifier token usage",
  ))
  runtime.Decoded(
    model,
    answers,
    Some(message.Usage(input, output, input + output)),
  )
}

/// TypeSafe-specific JSON parsing precedes provider-neutral admission.
pub fn decode_answers(
  raw: value.Value,
) -> Result(List(#(String, protocol.Answer)), wire.Error) {
  use answers <- result.try(wire.object(raw))
  list.try_map(answers, fn(entry) {
    use fields <- result.try(wire.object(entry.1))
    use kind <- result.try(
      wire.required(fields, "type") |> result.try(wire.text),
    )
    use answer <- result.map(case kind {
      "noul" -> {
        use raw <- result.try(wire.required(fields, "noul"))
        wire.between(raw, 0, 1) |> result.map(protocol.Yes)
      }
      "choice" -> {
        use selected <- result.try(
          wire.required(fields, "choice") |> result.try(wire.text),
        )
        use probabilities <- result.try(probabilities(fields))
        use confidence <- result.map(confidence(fields))
        protocol.Selected(selected, probabilities, Some(confidence))
      }
      "score" -> {
        use position <- result.try(
          wire.required(fields, "score") |> result.try(wire.between(_, 0, 9)),
        )
        use probabilities <- result.try(probabilities(fields))
        use probabilities <- result.try(
          list.try_map(probabilities, fn(p) {
            use index <- result.map(index(p.0))
            #(index, p.1)
          }),
        )
        use legend <- result.try(
          wire.required(fields, "legend") |> result.try(wire.object),
        )
        use levels <- result.try(
          list.try_map(legend, fn(p) {
            use index <- result.map(index(p.0))
            #(index, p.1)
          }),
        )
        let levels = list.sort(levels, fn(a, b) { int.compare(a.0, b.0) })
        use Nil <- result.try(wire.require(
          list.map(levels, fn(p) { p.0 })
            == list.index_map(levels, fn(_, i) { i }),
          "Score legend indices are not consecutive",
        ))
        use confidence <- result.map(confidence(fields))
        protocol.Rated(
          position,
          probabilities,
          list.map(levels, fn(p) { p.1 }),
          Some(confidence),
        )
      }
      _ -> Error(wire.InvalidValue("unknown classifier answer kind"))
    })
    #(entry.0, answer)
  })
}

fn index(raw: String) -> Result(Int, wire.Error) {
  use n <- result.try(
    int.parse(raw)
    |> result.replace_error(wire.InvalidValue("invalid Score index")),
  )
  use Nil <- result.map(wire.require(
    n >= 0 && n <= 9 && int.to_string(n) == raw,
    "invalid Score index",
  ))
  n
}

fn probabilities(
  fields: List(#(String, value.Value)),
) -> Result(List(#(String, Float)), wire.Error) {
  use raw <- result.try(
    wire.required(fields, "probabilities") |> result.try(wire.object),
  )
  list.try_map(raw, fn(p) {
    use n <- result.map(wire.between(p.1, 0, 1))
    #(p.0, n)
  })
}

fn confidence(
  fields: List(#(String, value.Value)),
) -> Result(Float, wire.Error) {
  wire.required(fields, "confidence") |> result.try(wire.between(_, 0, 1))
}
