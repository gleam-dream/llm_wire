import http_gun
import http_gun/config
import http_gun/fixture
import http_gun/testing as http_testing
import llm_wire/session
import llm_wire/testing

/// Tests own this client for the complete callback, including streamed reads.
pub fn with_client(run: fn(http_gun.Client) -> value) -> value {
  with_settings(config.Config(..config.default(), deadline_ms: 60_000), run)
}

pub fn with_settings(
  settings: config.Config,
  run: fn(http_gun.Client) -> value,
) -> value {
  let assert Ok(client) = http_gun.start(settings)
  let outcome = run(client)
  let assert Ok(Nil) = http_gun.stop(client)
  outcome
}

pub fn with_script(
  exchanges: List(fixture.Exchange),
  run: fn(http_gun.Client) -> value,
) -> value {
  let assert Ok(client) =
    http_testing.start(
      config.Config(..config.default(), deadline_ms: 60_000),
      exchanges,
    )
  let outcome = run(client)
  let assert Ok(Nil) = http_gun.stop(client)
  outcome
}

pub fn run_reply(
  prepared: session.PreparedCall,
  reply: testing.Reply,
) -> Result(session.RunResult, session.RunFailure) {
  use client <- with_script([testing.exchange(prepared, reply)])
  session.run(client, prepared)
}

pub fn run_structured_reply(
  prepared: session.PreparedStructuredCall(output),
  reply: testing.Reply,
) -> Result(session.StructuredRunResult(output), session.RunFailure) {
  use client <- with_script([testing.structured_exchange(prepared, reply)])
  session.run_structured(client, prepared)
}
