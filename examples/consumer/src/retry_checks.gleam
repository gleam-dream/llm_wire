//// Offline regression checks for the application's retry policy.

import gleam/list
import gleam/option.{Some}
import gleam/time/duration
import http_gun
import http_gun/config
import http_gun/deadline
import http_gun/testing as http_testing
import llm_wire
import llm_wire/error
import llm_wire/message
import llm_wire/testing
import llm_wire_consumer as consumer

pub fn main() -> Nil {
  let assert Ok(call) =
    llm_wire.prepare(
      testing.config(),
      llm_wire.request("test", [llm_wire.user("hi")]),
    )
  // A finite attempt count does not bound a provider's requested wait.
  let assert Ok(client) =
    http_testing.playback(
      http_testing.script([
        testing.exchange(call, testing.rate_limited(message.Custom("scripted")))
          |> testing.with_retry_after(duration.seconds(86_400)),
        testing.exchange(call, testing.text("not retried")),
      ]),
      config.default(),
    )
  // Leave room for cold runtime startup; the wall bound still rejects waiting.
  let wall = deadline.after(duration.milliseconds(500))
  let assert Error(consumer.ProviderFailure(failure)) =
    consumer.run_with_retries(
      client,
      call,
      3,
      duration.seconds(0),
      duration.seconds(5),
    )
  let assert error.Status(429, _, Some(wait)) = failure.error
  let assert 86_400_000 = duration.to_milliseconds(wait)
  let assert llm_wire.Completed = failure.sent
  let assert True = duration.to_milliseconds(deadline.remaining(wall)) > 0
  // The second exchange remains available: budget refusal made no attempt.
  let assert Ok(llm_wire.Answer(text: "not retried", ..)) =
    llm_wire.run(client, call)
  http_gun.stop(client)

  let limited =
    testing.exchange(call, testing.rate_limited(message.Custom("scripted")))
    |> testing.with_retry_after(duration.seconds(1))
  let assert Ok(client) =
    http_testing.playback(
      http_testing.script([
        limited,
        limited,
        testing.exchange(call, testing.text("untouched")),
      ]),
      config.default(),
    )
  // First wait fits; the second does not fit the same deadline.
  let assert Error(consumer.ProviderFailure(failure)) =
    consumer.run_with_retries(
      client,
      call,
      5,
      duration.seconds(0),
      duration.milliseconds(1500),
    )
  let assert error.Status(429, _, _) = failure.error
  let assert Ok(llm_wire.Answer(text: "untouched", ..)) =
    llm_wire.run(client, call)
  http_gun.stop(client)

  let limited =
    testing.exchange(call, testing.rate_limited(message.Custom("scripted")))
    |> testing.with_retry_after(duration.seconds(0))
  let assert Ok(client) =
    http_testing.playback(
      http_testing.script([
        limited,
        limited,
        testing.exchange(call, testing.text("untouched")),
      ]),
      config.default(),
    )
  let assert Error(consumer.ProviderFailure(_)) =
    consumer.run_with_retries(
      client,
      call,
      2,
      duration.seconds(0),
      duration.seconds(5),
    )
  let assert Ok(llm_wire.Answer(text: "untouched", ..)) =
    llm_wire.run(client, call)
  http_gun.stop(client)

  let assert Ok(client) =
    http_testing.playback(
      http_testing.script([
        limited,
        testing.exchange(call, testing.text("retried")),
      ]),
      config.default(),
    )
  let assert Ok(llm_wire.Answer(text: "retried", ..)) =
    consumer.run_with_retries(
      client,
      call,
      2,
      duration.seconds(0),
      duration.seconds(5),
    )
  http_gun.stop(client)

  let assert Ok(client) =
    http_testing.playback(
      http_testing.script([testing.exchange(call, testing.text("untouched"))]),
      config.default(),
    )
  list.each(
    [
      #(0, duration.seconds(1), duration.seconds(0)),
      #(-1, duration.seconds(1), duration.seconds(0)),
      #(2, duration.seconds(0), duration.seconds(0)),
      #(2, duration.seconds(-1), duration.seconds(0)),
      #(2, duration.milliseconds(4_294_967_296), duration.seconds(0)),
      #(2, duration.seconds(1), duration.milliseconds(-1)),
    ],
    fn(policy) {
      let assert Error(consumer.InvalidRetryBudget) =
        consumer.run_with_retries(client, call, policy.0, policy.2, policy.1)
    },
  )
  let assert Ok(llm_wire.Answer(text: "untouched", ..)) =
    llm_wire.run(client, call)
  http_gun.stop(client)
}
