//// Local HTTP evidence: time in an attempt consumes the shared retry budget.

import gleam/erlang/process
import gleam/time/duration
import http_gun
import http_gun/config
import http_gun/deadline
import http_gun/destination
import llm_wire
import llm_wire/error
import llm_wire/openai
import llm_wire_consumer as consumer

@external(erlang, "retry_fixture", "endpoint")
fn endpoint() -> String

pub fn main() -> Nil {
  let assert Ok(client) =
    http_gun.start(
      config.default() |> config.with_destination(destination.loopback_only()),
    )
  let settings =
    openai.new("local-fixture")
    |> openai.config
    |> llm_wire.with_call_timeout(llm_wire.Infinity)
    |> llm_wire.with_first_token_timeout(llm_wire.Infinity)
    |> llm_wire.with_idle_timeout(llm_wire.Infinity)
  let request = llm_wire.request("fixture", [llm_wire.user("hi")])
  let assert Ok(call) =
    llm_wire.prepare(
      settings |> llm_wire.with_endpoint(endpoint() <> "/slow"),
      request,
    )
  let wall = deadline.after(duration.seconds(2))
  let assert Error(consumer.RetryDeadlineReached) =
    consumer.run_with_retries(
      client,
      call,
      3,
      duration.seconds(0),
      duration.milliseconds(300),
    )
  let assert True = duration.to_milliseconds(deadline.remaining(wall)) > 0
  wait_for_release(client, 100)

  // 250ms in the first attempt leaves less than the 200ms fallback.
  let assert Ok(call) =
    llm_wire.prepare(
      settings |> llm_wire.with_endpoint(endpoint() <> "/delayed-failure"),
      request,
    )
  let assert Error(consumer.ProviderFailure(failure)) =
    consumer.run_with_retries(
      client,
      call,
      3,
      duration.milliseconds(200),
      duration.milliseconds(400),
    )
  let assert error.Status(503, _, _) = failure.error
  wait_for_release(client, 100)
  http_gun.stop(client)
}

fn wait_for_release(client: http_gun.Client, attempts: Int) -> Nil {
  let assert Ok(stats) = http_gun.stats(client)
  case stats.open_bodies, stats.queued_requests {
    0, 0 -> Nil
    _, _ -> {
      let assert True = attempts > 0
      process.sleep(10)
      wait_for_release(client, attempts - 1)
    }
  }
}
