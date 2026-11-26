//// A local measurement, not a test: how long the Gemini reducer takes to
//// read one event whose function-call arguments hold a large array.
//// Run with `gleam run -m google_part_encoding_bench`.

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/string
import llm_wire/internal/google
import llm_wire/internal/limits
import llm_wire/internal/sse

@external(erlang, "llm_wire_measure_ffi", "now")
fn now_microseconds() -> Int

/// One Gemini event whose single function call carries an array of
/// `elements` small integers.
pub fn event(elements: Int) -> sse.ServerSentEvent {
  let items = list.repeat("1", elements) |> string.join(",")
  sse.ServerSentEvent(
    event: None,
    data: "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"calc\",\"id\":\"call_1\",\"args\":{\"items\":["
      <> items
      <> "]}}}]}}]}",
    id: None,
    retry: None,
  )
}

fn measure(elements: Int) -> Int {
  let input = event(elements)
  let reducer = google.new(limits.default())
  let started = now_microseconds()
  let _ = google.step(reducer, input)
  now_microseconds() - started
}

pub fn main() -> Nil {
  list.each([5000, 20_000, 80_000], fn(elements) {
    let runs = list.map([1, 2, 3, 4, 5], fn(_) { measure(elements) })
    io.println(
      int.to_string(elements)
      <> " elements, microseconds per event: "
      <> string.join(list.map(runs, int.to_string), " "),
    )
  })
}
