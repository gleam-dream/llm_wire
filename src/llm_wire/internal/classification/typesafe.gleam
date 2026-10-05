import gleam/list
import gleam/result
import gleam/string
import json/blueprint/value
import llm_wire/error
import llm_wire/internal/classification/runtime
import llm_wire/internal/classification/wire
import llm_wire/message

pub fn wire(reveal: fn() -> String) -> runtime.Wire {
  runtime.wire(
    message.Custom("typesafe"),
    "https://api.typesafe.ai/v1/systemone",
    fn() { [#("authorization", "Bearer " <> reveal())] },
    encode,
    decode,
  )
  |> runtime.with_validation(fn() {
    let key = reveal()
    case
      key != ""
      && list.all(string.to_utf_codepoints(key), fn(c) {
        let n = string.utf_codepoint_to_int(c)
        n > 32 && n < 127
      })
    {
      True -> Ok(Nil)
      False ->
        Error(error.InvalidSetting(
          error.ApiKey,
          "must be nonempty visible ASCII",
        ))
    }
  })
}

fn encode(
  model: String,
  state: value.Value,
  questions: value.Value,
) -> Result(String, error.PrepareError) {
  use state <- result.map(
    wire.content(state)
    |> result.map_error(fn(detail) {
      error.InvalidRequest(error.InvalidClassificationContent(detail))
    }),
  )
  value.to_string(
    value.Object([
      #("model", value.String(model)),
      #("state", state),
      #("questions", questions),
    ]),
  )
}

fn decode(raw: String) -> Result(runtime.Decoded, error.Error) {
  decode_response(raw) |> result.map_error(error.Protocol)
}

fn decode_response(raw: String) -> Result(runtime.Decoded, String) {
  use fields <- result.try(wire.parse(raw) |> result.try(wire.object))
  use model <- result.try(
    wire.required(fields, "model") |> result.try(wire.text),
  )
  use answers <- result.try(wire.required(fields, "answers"))
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
  runtime.Decoded(model, answers, message.Usage(input, output, input + output))
}
