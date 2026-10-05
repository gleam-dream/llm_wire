import gleam/float
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import json/blueprint/codec
import json/blueprint/number
import json/blueprint/value.{type Value}
import llm_wire/error

/// Internal validation retains typed causes until a public boundary renders
/// a safe description. No decoder or question builder uses string errors.
pub type Error {
  InvalidJson(value.ParseError)
  MissingField(String)
  InvalidValue(String)
  PreparationFailed(error.PrepareError)
  ResponseFailed(error.Error)
}

pub fn describe_error(problem: Error) -> String {
  case problem {
    InvalidJson(_) -> "invalid or unbounded classifier JSON"
    MissingField(key) -> "missing classifier field: " <> key
    InvalidValue(detail) -> detail
    PreparationFailed(problem) -> error.describe_prepare_error(problem)
    ResponseFailed(problem) -> error.describe(problem)
  }
}

pub fn parse(raw: String) -> Result(Value, Error) {
  // Byte admission belongs to preparation, HTTP collection and receipt
  // restoration. This parse checks an already materialized string without
  // imposing a second byte cap; structural and numeric limits stay bounded.
  value.parse(
    raw,
    value.default_limits() |> value.with_max_bytes(string.byte_size(raw)),
  )
  |> result.map_error(InvalidJson)
}

pub fn content(raw: Value) -> Result(Value, Error) {
  use value <- result.try(parse(value.to_string(raw)))
  case value {
    value.String(_) | value.Object(_) | value.Array(_) -> Ok(value)
    _ ->
      Error(InvalidValue(
        "classifier content must be text, an object or an array",
      ))
  }
}

pub fn object(raw: Value) -> Result(List(#(String, Value)), Error) {
  case raw {
    value.Object(fields) ->
      value.object(fields)
      |> result.map(fn(_) { fields })
      |> result.map_error(fn(_) {
        InvalidValue("duplicate classifier object key")
      })
    _ -> Error(InvalidValue("expected classifier object"))
  }
}

pub fn required(
  fields: List(#(String, Value)),
  key: String,
) -> Result(Value, Error) {
  list.key_find(fields, key)
  |> result.map_error(fn(_) { MissingField(key) })
}

pub fn text(raw: Value) -> Result(String, Error) {
  case raw {
    value.String(text) ->
      require(string.trim(text) != "", "expected nonempty classifier text")
      |> result.map(fn(_) { text })
    _ -> Error(InvalidValue("expected nonempty classifier text"))
  }
}

pub fn integer(raw: Value) -> Result(Int, Error) {
  codec.decode(codec.int(), raw)
  |> result.map_error(fn(_) { InvalidValue("expected classifier integer") })
}

pub fn between(raw: Value, minimum: Int, maximum: Int) -> Result(Float, Error) {
  use n <- result.try(case raw {
    value.Number(n) -> Ok(n)
    _ -> Error(InvalidValue("expected classifier number"))
  })
  use low <- result.try(
    number.from_int(minimum)
    |> result.map_error(fn(_) { InvalidValue("invalid numeric lower bound") }),
  )
  use high <- result.try(
    number.from_int(maximum)
    |> result.map_error(fn(_) { InvalidValue("invalid numeric upper bound") }),
  )
  use Nil <- result.try(require(
    number.compare(n, low) != order.Lt && number.compare(n, high) != order.Gt,
    "classifier number is outside its valid range",
  ))
  let text = number.to_string(n)
  let native_text = case string.split(text, "e") {
    [coefficient, exponent] -> decimal(coefficient) <> "e" <> exponent
    _ -> decimal(text)
  }
  use projected <- result.try(
    float.parse(native_text)
    |> result.map_error(fn(_) {
      InvalidValue("classifier number cannot be represented natively")
    }),
  )
  use Nil <- result.map(require(
    !{ minimum == 0 && projected == 0.0 && number.compare(n, low) == order.Gt },
    "classifier number underflows native precision",
  ))
  projected
}

fn decimal(text: String) -> String {
  case string.contains(text, ".") {
    True -> text
    False -> text <> ".0"
  }
}

pub fn require(condition: Bool, error: String) -> Result(Nil, Error) {
  case condition {
    True -> Ok(Nil)
    False -> Error(InvalidValue(error))
  }
}

pub fn keys(fields: List(#(String, a))) -> List(String) {
  list.map(fields, fn(field) { field.0 })
}

pub fn same_keys(fields: List(#(String, a)), expected: List(String)) -> Bool {
  list.length(fields) == list.length(expected)
  && list.all(fields, fn(field) { list.contains(expected, field.0) })
}

/// Object order has no semantic significance in structured rubrics.
pub fn canonical(raw: Value) -> Value {
  case raw {
    value.Object(fields) ->
      value.Object(
        fields
        |> list.map(fn(field) { #(field.0, canonical(field.1)) })
        |> list.sort(fn(left, right) { string.compare(left.0, right.0) }),
      )
    value.Array(items) -> value.Array(list.map(items, canonical))
    other -> other
  }
}
