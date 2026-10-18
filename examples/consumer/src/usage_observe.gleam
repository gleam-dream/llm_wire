//// Observe: subscribe to `[llm_wire, observation]` through Sinal and join the
//// events to HTTP Gun's by one correlation set on the HTTP Gun view.

import gleam/erlang/process
import gleam/io
import gleam/option.{Some}
import http_gun
import http_gun/config as http_config
import http_gun/testing as http_testing
import llm_wire
import llm_wire/message
import llm_wire/openai
import llm_wire/telemetry
import llm_wire/testing
import sinal
import sinal/correlation
import usage_support.{prepared}

fn wait_for_terminal(
  events: process.Subject(telemetry.Metadata),
) -> telemetry.Metadata {
  let assert Ok(event) = process.receive(events, 2000)
  case event.stage {
    telemetry.Terminal -> event
    _ -> wait_for_terminal(events)
  }
}

pub fn main() -> Nil {
  let events = process.new_subject()
  let attachment =
    sinal.observe(telemetry.event(), fn(_, metadata) {
      process.send(events, metadata)
    })

  let config = openai.new("sk-example") |> openai.config
  let request = llm_wire.request("gpt-5", [llm_wire.user("Hello")])
  let call = prepared(config, request)
  let reply = testing.events_for(message.OpenAI, testing.text("Hello!"))
  let assert Ok(client) =
    http_testing.playback(
      http_testing.script([testing.exchange(call, reply)]),
      http_config.default(),
    )

  // Set the correlation once, on the HTTP Gun view the call runs on.
  let job = correlation.from_key("job-1")
  let assert Ok(llm_wire.Answer(text: "Hello!", ..)) =
    llm_wire.run(http_gun.with_correlation(client, job), call)
  http_gun.stop(client)

  // The terminal event carries the call, the caller's correlation, a fixed
  // stage and outcome, and never any content or credentials.
  let terminal = wait_for_terminal(events)
  let assert Some(seen) = terminal.correlation
  let assert True = seen == job
  let assert telemetry.Answered = terminal.outcome
  io.println(
    "call "
    <> terminal.call
    <> " "
    <> telemetry.stage_name(terminal.stage)
    <> " "
    <> telemetry.outcome_name(terminal.outcome),
  )
  let assert Ok(Nil) = sinal.detach(attachment)
  Nil
}
