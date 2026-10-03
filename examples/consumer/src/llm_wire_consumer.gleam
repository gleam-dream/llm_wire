//// Public imports from the actual migrated checkout. No archived demo or internals.

import gleam/erlang/process
import gleam/list
import gleam/otp/supervision
import http_gun
import http_gun/cassette
import http_gun/config as http_config
import http_gun/testing as http_testing
import llm_wire/config
import llm_wire/session
import llm_wire/testing
import llm_wire/types

pub fn http_policy() -> http_config.Config {
  // Each LLM call's own budget replaces the client's request timeout, so the
  // HTTP Gun defaults need no raised ceiling.
  http_config.default()
}

/// Supervise the shared client under `name`; `http_gun.named(name)` reaches
/// it from anywhere, across restarts.
pub fn http_child(
  name: process.Name(http_gun.Message),
) -> supervision.ChildSpecification(http_gun.Client) {
  http_gun.supervised(http_policy(), name)
}

/// The application's handle to the supervised client.
pub fn http_client(name: process.Name(http_gun.Message)) -> http_gun.Client {
  http_gun.named(name)
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
  http_gun.stop(client)
  Nil
}

pub fn record(call: session.PreparedCall, destination: String) -> Nil {
  let assert Ok(recorded) =
    cassette.record(
      http_policy(),
      destination,
      cassette.options() |> cassette.with_max_bytes(1_000_000),
    )
  flow(recorded.client, call)
  let assert Ok(_) = cassette.finish(recorded.recording, 5000)
  http_gun.stop(recorded.client)
  Nil
}

pub fn playback(call: session.PreparedCall, path: String) -> Nil {
  let assert Ok(script) = cassette.load(path, 1_000_000)
  let assert Ok(client) = http_testing.playback(script, http_policy())
  flow(client, call)
  http_gun.stop(client)
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
  let script = http_testing.script(exchanges)
  let assert Ok(client) = http_testing.playback(script, http_policy())
  flow(client, call)
  let assert Error(session.RunFailure(types.HttpFailure(_), _)) =
    session.run(client, call)
  http_gun.stop(client)
  let assert Ok(script) = cassette.parse(cassette.encode(script), 1_000_000)
  let assert Ok(client) = http_testing.playback(script, http_policy())
  flow(client, call)
  http_gun.stop(client)
  Nil
}
