//// Defaults, timeouts and limits: choose them on the `Config`, and see which
//// setting a failure names when a bound is exceeded.

import gleam/io
import gleam/list
import gleam/time/duration
import llm_wire
import llm_wire/error
import llm_wire/limit
import llm_wire/message
import llm_wire/openai
import llm_wire/testing
import usage_support.{prepared, scripted}

pub fn main() -> Nil {
  // Every limit has a finite default and a stable name.
  let assert 1_048_576 = limit.default(limit.RequestBytes)
  let assert 8_388_608 = limit.default(limit.ResponseBodyBytes)
  let assert 500 = limit.default(limit.QueueCount)
  let assert True = list.length(limit.all()) > 10
  let assert "total_text_bytes" = limit.name(limit.TotalTextBytes)

  // A configuration chooses timeouts and limits. `Infinity` lifts a timeout
  // and must be chosen explicitly.
  let config =
    openai.new("sk-example")
    |> openai.config
    |> llm_wire.with_endpoint("https://api.example.test/v1")
    |> llm_wire.with_call_timeout(llm_wire.After(duration.minutes(5)))
    |> llm_wire.with_first_token_timeout(llm_wire.After(duration.seconds(30)))
    |> llm_wire.with_idle_timeout(llm_wire.Infinity)
    |> llm_wire.with_limit(limit.TotalTextBytes, 4)
  let request = llm_wire.request("gpt-5", [llm_wire.user("Say hello")])
  let call = prepared(config, request)

  // A call that exceeds a limit fails and names the setting that raises it.
  let reply = testing.events_for(message.OpenAI, testing.text("Hello, world"))
  let assert Error(
    llm_wire.Failure(
      error: error.LimitExceeded(
        limit: limit.TotalTextBytes,
        limit_value: 4,
        ..,
      ),
      ..,
    ) as failure,
  ) = {
    use client <- scripted([testing.exchange(call, reply)])
    llm_wire.run(client, call)
  }
  io.println("limit exceeded: " <> llm_wire.describe_failure(failure))
}
