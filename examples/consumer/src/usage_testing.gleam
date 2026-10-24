//// Test without a network: describe replies, lower them into a provider's
//// wire, script exchanges and failures, and serve a reply from a fake server.

import gleam/io
import gleam/list
import gleam/option.{None}
import gleam/time/duration
import http_gun/config as http_config
import http_gun/testing as http_testing
import llm_wire
import llm_wire/error
import llm_wire/message
import llm_wire/testing

pub fn main() -> Nil {
  // The offline configuration and a script of one exchange.
  let request = llm_wire.request("test-model", [llm_wire.user("hello")])
  let assert Ok(call) = llm_wire.prepare(testing.config(), request)
  let script = http_testing.script([testing.exchange(call, testing.text("hi"))])
  let assert Ok(client) = http_testing.playback(script, http_config.default())
  let assert Ok(llm_wire.Answer(text: "hi", ..)) = llm_wire.run(client, call)

  // A `Reply` is opaque. Constructors describe what a provider sends,
  // including its failures.
  let replies = [
    testing.text("done") |> testing.with_usage(message.Usage(1, 2, 3)),
    testing.tool_calls("", [testing.tool_call("c1", "lookup", "{}")]),
    testing.refusal("declined"),
    testing.output_limited("cut"),
    testing.content_filtered("partial"),
    testing.prompt_blocked(),
    testing.invalid_output(),
    testing.rate_limited(message.OpenAI),
    testing.overloaded(message.Anthropic),
    testing.http_status(message.Custom("acme"), 501, "not implemented"),
    testing.interrupted(testing.text("partial")),
    testing.events(["event: delta\ndata: hi\n\n"]),
  ]
  let assert 12 = list.length(replies)

  // Lower a reply into a built-in provider's wire, then serve it as a fake
  // server would: a status, the chunks, and whether the stream is cut short.
  let lowered = testing.events_for(message.OpenAI, testing.text("hello"))
  let assert 200 = testing.status(lowered)
  let assert True = testing.chunks(lowered) != []
  let assert False = testing.is_interrupted(lowered)
  let cut =
    testing.events_for(message.OpenAI, testing.interrupted(testing.text("x")))
  let assert True = testing.is_interrupted(cut)
  let served = testing.http_response(message.OpenAI, lowered)
  let assert 200 = served.status

  // `with_retry_after` adds the header to a scripted failure.
  let limited =
    testing.exchange(call, testing.rate_limited(message.OpenAI))
    |> testing.with_retry_after(duration.seconds(2))
  let assert Error(llm_wire.Failure(error: error.Status(429, _, _), ..)) = {
    let assert Ok(rate_client) =
      http_testing.playback(
        http_testing.script([limited]),
        http_config.default(),
      )
    llm_wire.run(rate_client, call)
  }

  // Build a `Failure` for code that only consumes failures.
  let failure = testing.failure(message.OpenAI, error.Status(429, "slow", None))
  io.println(llm_wire.describe_failure(failure))
}
