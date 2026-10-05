//// Opt-in one-call recording; invoked only by dev/record-live.

import classification_live_scenario as scenario
import gleam/io
import gleam/time/duration
import http_gun
import http_gun/cassette
import live_scenarios
import llm_wire
import llm_wire/classify

@external(erlang, "llm_wire_live_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

pub fn main() -> Nil {
  let reveal = fn() {
    let assert Ok(key) = getenv("TYPESAFE_API_KEY")
    key
  }
  let call = scenario.prepared(reveal)
  let assert Ok(recorded) =
    cassette.record(
      live_scenarios.http(),
      "test/cassettes/live/typesafe-classification.json",
      cassette.options()
        |> cassette.with_max_bytes(1_000_000)
        |> cassette.replace_existing,
    )
  let outcome = classify.run(recorded.client, call)
  case outcome {
    Ok(answer) -> {
      let assert Ok(_) =
        cassette.finish(recorded.recording, duration.seconds(5))
      io.println("typesafe-classification: " <> answer.resolved_model)
    }
    Error(failure) -> {
      let _ = cassette.abort(recorded.recording)
      http_gun.stop(recorded.client)
      panic as llm_wire.describe_failure(failure)
    }
  }
  http_gun.stop(recorded.client)
}
