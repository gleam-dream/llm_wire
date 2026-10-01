//// Public imports from the actual migrated checkout. No archived demo or internals.

import gleam/erlang/process
import gleam/list
import gleam/otp/supervision
import http_gun
import http_gun/cassette
import http_gun/config as http_config
import http_gun/recording
import http_gun/testing as http_testing
import llm_wire/config
import llm_wire/session
import llm_wire/testing
import llm_wire/types

pub fn http_policy() -> http_config.Config {
  // HTTP Gun applies this ceiling even when an LLM call has a longer budget.
  http_config.Config(..http_config.default(), deadline_ms: 120_000)
}

/// Publish each newly supervised capability to the application's registry.
/// A restart replaces the client; callers must obtain the new capability.
pub fn http_child(
  ready: process.Subject(http_gun.Client),
) -> supervision.ChildSpecification(Nil) {
  http_gun.child(http_policy())
  |> supervision.map_data(fn(client) { process.send(ready, client) })
}

/// The same flow accepts live, scripted, playback and recording clients.
pub fn flow(client: http_gun.Client, call: session.PreparedCall) -> Nil {
  let assert Ok(session.RunText("hello", _)) = session.run(client, call)
  let assert Ok(stream) = session.stream(client, call)
  let assert Ok(session.NextProgress(_)) = session.next(stream)
  let _ = session.close(stream)
  let done = process.new_subject()
  list.each(list.repeat(Nil, 10), fn(_) {
    let _ =
      process.spawn(fn() { process.send(done, session.run(client, call)) })
    Nil
  })
  list.each(list.repeat(Nil, 10), fn(_) {
    let assert Ok(Ok(session.RunText("hello", _))) = process.receive(done, 5000)
    Nil
  })
}

pub fn live(call: session.PreparedCall) -> Nil {
  let assert Ok(client) = http_gun.start(http_policy())
  flow(client, call)
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}

pub fn record(call: session.PreparedCall, destination: String) -> Nil {
  let assert Ok(recorded) =
    cassette.record(
      http_policy(),
      destination,
      recording.Options(1_000_000, recording.RefuseExisting),
    )
  flow(recorded.client, call)
  let assert Ok(_) = recording.finish_wait(recorded.recording, 5000)
  let assert Ok(Nil) = http_gun.stop(recorded.client)
  Nil
}

pub fn playback(call: session.PreparedCall, path: String) -> Nil {
  let assert Ok(tape) = cassette.load(path, 1_000_000)
  let assert Ok(client) = cassette.playback(tape, http_policy())
  flow(client, call)
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}

pub fn main() -> Nil {
  let assert Ok(model) = types.model_id("synthetic-model")
  let settings: config.Config = testing.config()
  let assert Ok(call) =
    session.prepare(
      settings,
      types.new_request(model, [types.UserMessage("hi")]),
    )
  // Concurrent identical requests deliberately have identical replies. Distinct
  // order-sensitive exchanges require application-controlled admission ordering.
  let exchanges = list.repeat(testing.exchange(call, testing.text("hello")), 12)
  let assert Ok(client) = http_testing.start(http_policy(), exchanges)
  flow(client, call)
  let assert Error(session.RunFailure(types.HttpFailure(_), _)) =
    session.run(client, call)
  let assert Ok(Nil) = http_gun.stop(client)
  let assert Ok(tape) = cassette.new(exchanges)
  let assert Ok(tape) = cassette.parse(cassette.encode(tape), 1_000_000)
  let assert Ok(client) = cassette.playback(tape, http_policy())
  flow(client, call)
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}
