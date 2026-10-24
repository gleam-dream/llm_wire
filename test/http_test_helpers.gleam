import http_gun
import http_gun/config
import http_gun/destination
import http_gun/testing as http_testing
import llm_wire
import llm_wire/testing

/// HTTP Gun's default policy admits public destinations only. Local fake
/// servers listen on loopback, so live test clients opt into it explicitly.
pub fn loopback_config() -> config.Config {
  config.default()
  |> config.with_destination(
    destination.default() |> destination.allow_loopback,
  )
}

/// Tests own this client for the complete callback, including streamed reads.
pub fn with_client(run: fn(http_gun.Client) -> value) -> value {
  with_settings(loopback_config(), run)
}

pub fn with_settings(
  settings: config.Config,
  run: fn(http_gun.Client) -> value,
) -> value {
  let assert Ok(client) = http_gun.start(settings)
  let outcome = run(client)
  http_gun.stop(client)
  outcome
}

pub fn with_script(
  exchanges: List(http_testing.Exchange),
  run: fn(http_gun.Client) -> value,
) -> value {
  let assert Ok(client) =
    http_testing.playback(http_testing.script(exchanges), config.default())
  let outcome = run(client)
  http_gun.stop(client)
  outcome
}

pub fn run_reply(
  prepared: llm_wire.Prepared(o),
  reply: testing.Reply,
) -> Result(llm_wire.Outcome(o), llm_wire.Failure) {
  use client <- with_script([testing.exchange(prepared, reply)])
  llm_wire.run(client, prepared)
}
