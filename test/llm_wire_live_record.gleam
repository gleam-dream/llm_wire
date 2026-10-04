//// Opt-in live recording, never part of the gate. Run it with
//// `sh dev/record-live [scenario ...]`, which loads the keys from the
//// git-ignored `.env.local`. Each named scenario of `live_scenarios` (all by
//// default) calls the live provider once and writes its redacted cassette
//// to `test/cassettes/live/`. The first failure aborts that cassette and
//// stops the run; keys are read from the environment and never printed.

import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun
import http_gun/cassette
import live_scenarios.{type Scenario}
import llm_wire
import llm_wire/error
import simplifile

@external(erlang, "llm_wire_live_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "llm_wire_live_ffi", "arguments")
fn arguments() -> List(String)

@external(erlang, "erlang", "halt")
fn halt(status: Int) -> Nil

pub fn main() -> Nil {
  let scenarios = case arguments() {
    [] -> Ok(live_scenarios.all())
    names ->
      list.try_map(names, fn(name) {
        live_scenarios.from_name(name) |> result.replace_error(name)
      })
  }
  case scenarios {
    Error(name) -> {
      io.println_error("Unknown scenario: " <> name)
      halt(2)
    }
    Ok(scenarios) ->
      case list.try_each(scenarios, record) {
        Ok(Nil) -> io.println("Recorded every scenario.")
        Error(Nil) -> halt(1)
      }
  }
}

fn key(scenario: Scenario) -> Result(String, Nil) {
  let variable = case live_scenarios.is_google(scenario) {
    True -> "GEMINI_API_KEY"
    False -> "OPENAI_API_KEY"
  }
  getenv(variable)
  |> result.map_error(fn(_) {
    io.println_error(variable <> " is not set; load .env.local first.")
  })
}

fn record(scenario: Scenario) -> Result(Nil, Nil) {
  use key <- result.try(key(scenario))
  let path = live_scenarios.path(scenario)
  let assert Ok(recorded) =
    cassette.record(
      live_scenarios.http(),
      path,
      cassette.options()
        |> cassette.with_max_bytes(1_000_000)
        |> cassette.replace_existing,
    )
  let outcome = case scenario {
    live_scenarios.GoogleText ->
      llm_wire.run(recorded.client, live_scenarios.text_call(key))
      |> result.map(summary)
    live_scenarios.GoogleTool ->
      llm_wire.run(recorded.client, live_scenarios.tool_call(key))
      |> result.map(summary)
    live_scenarios.GoogleNullableNull | live_scenarios.GoogleNullableValue ->
      llm_wire.run(recorded.client, live_scenarios.nullable_call(scenario, key))
      |> result.map(summary)
    live_scenarios.GoogleWideSchema ->
      llm_wire.run(recorded.client, live_scenarios.wide_call(key))
      |> result.map(summary)
    _ ->
      llm_wire.run(
        recorded.client,
        live_scenarios.structured_call(scenario, key),
      )
      |> result.map(summary)
  }
  let name = live_scenarios.name(scenario)
  let published = case outcome {
    Ok(line) -> {
      io.println(name <> ": " <> line)
      cassette.finish(recorded.recording, duration.seconds(5))
      |> result.map(fn(file) { io.println("  wrote " <> file) })
      |> result.map_error(fn(problem) {
        io.println_error("  " <> cassette.describe_finish_error(problem))
      })
    }
    Error(failure) -> {
      let _ = cassette.abort(recorded.recording)
      io.println_error(name <> " failed: " <> describe(failure))
      Error(Nil)
    }
  }
  http_gun.stop(recorded.client)
  remove_staging(name)
  published
}

/// An aborted recording leaves its staging directory (`<file>.http-gun-*`)
/// next to the destination; remove it so a failed run leaves nothing.
fn remove_staging(name: String) -> Nil {
  let directory = "test/cassettes/live"
  let prefix = name <> ".json.http-gun-"
  case simplifile.read_directory(directory) {
    Ok(entries) ->
      list.each(entries, fn(entry) {
        case string.starts_with(entry, prefix) {
          True -> {
            let _ = simplifile.delete(directory <> "/" <> entry)
            Nil
          }
          False -> Nil
        }
      })
    Error(_) -> Nil
  }
}

fn summary(outcome: llm_wire.Outcome(o)) -> String {
  case outcome {
    llm_wire.Answer(output:, ..) -> "Answer " <> string.inspect(output)
    llm_wire.NeedsTools(turn:, ..) ->
      "NeedsTools "
      <> string.inspect(
        list.map(turn.calls, fn(c) { #(c.name, c.arguments_json) }),
      )
    llm_wire.OutputLimited(..) -> "OutputLimited"
    llm_wire.Refused(reason:, ..) -> "Refused " <> reason
  }
}

/// A provider's error body explains a rejected schema. An authentication
/// error body may quote part of the key, so only its status is shown.
fn describe(failure: llm_wire.Failure) -> String {
  case failure.error {
    error.Status(code, _, _) if code == 401 || code == 403 ->
      "HTTP " <> int.to_string(code)
    error.Status(code, body, _) ->
      "HTTP " <> int.to_string(code) <> " " <> string.slice(body, 0, 1500)
    _ -> llm_wire.describe_failure(failure)
  }
}
