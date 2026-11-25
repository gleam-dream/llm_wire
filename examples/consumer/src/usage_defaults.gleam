//// Defaults, timeouts and limits: choose them on the `Config`, and see which
//// setting a failure names when a bound is exceeded.

import gleam/io
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/duration
import llm_wire
import llm_wire/error
import llm_wire/google
import llm_wire/limit
import llm_wire/message
import llm_wire/openai
import llm_wire/testing
import llm_wire/thinking
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
    |> llm_wire.with_call_timeout(duration.minutes(5))
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

  thinking_level()
}

/// A thinking level bounds how much the model thinks. The output limit counts
/// thought and visible tokens together, so a level reserves no visible share;
/// usage shows afterwards how the limit was spent.
fn thinking_level() -> Nil {
  let config = google.new("example-key") |> google.config
  let request =
    llm_wire.request("gemini-3.8-flash", [llm_wire.user("Name a city")])
    |> llm_wire.with_max_tokens(1024)
    |> llm_wire.with_thinking_level(thinking.Low)
  let call = prepared(config, request)
  let assert True =
    string.contains(
      llm_wire.request_json(call),
      "\"thinkingConfig\":{\"thinkingLevel\":\"LOW\"}",
    )

  // A level the provider has no value for is refused before anything is sent.
  let assert Error(error.InvalidRequest(error.ThinkingUnsupported(error.LevelUnsupported(
    thinking.Max,
  )))) =
    llm_wire.prepare(
      config,
      request |> llm_wire.with_thinking_level(thinking.Max),
    )

  // A response cut off while thinking explains itself: of the output tokens
  // counted against the limit, `thought_tokens` were thought.
  let spent =
    message.Usage(
      input_tokens: 10,
      output_tokens: 1020,
      total_tokens: 1030,
      thought_tokens: Some(979),
    )
  let reply =
    testing.events_for(
      message.Google,
      testing.output_limited("") |> testing.with_usage(spent),
    )
  let assert Ok(llm_wire.OutputLimited(partial_text: "", usage: Some(usage), ..)) = {
    use client <- scripted([testing.exchange(call, reply)])
    llm_wire.run(client, call)
  }
  let assert Some(thought) = usage.thought_tokens
  io.println(
    "output limited: "
    <> string.inspect(usage.output_tokens)
    <> " output tokens, "
    <> string.inspect(thought)
    <> " of them thought",
  )
}
