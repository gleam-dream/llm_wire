//// Public consumer evidence for application-owned HTTP deadlines.

import gleam/option.{None}
import gleam/time/duration
import http_gun
import http_gun/config
import http_gun/deadline
import http_gun/testing as http_testing
import llm_wire
import llm_wire/error
import llm_wire/testing

pub fn main() -> Nil {
  let assert Ok(prepared) =
    llm_wire.prepare(
      testing.config(),
      llm_wire.request("fixture", [llm_wire.user("hi")]),
    )
  let assert Ok(client) =
    http_testing.playback(
      http_testing.script([
        testing.exchange(prepared, testing.text("still available")),
      ]),
      config.default(),
    )
  let expired = deadline.after(duration.milliseconds(0))
  let assert Error(failure) =
    llm_wire.run(http_gun.with_deadline(client, expired), prepared)
  let assert error.DeadlineExceeded(error.WholeCall) = failure.error
  let assert llm_wire.NotSent = failure.sent
  let assert False = failure.partial_output
  let assert None = failure.usage
  // Refusal must leave both the exchange and borrowed client usable.
  let assert Ok(llm_wire.Answer(text: "still available", ..)) =
    llm_wire.run(client, prepared)
  http_gun.stop(client)
}
