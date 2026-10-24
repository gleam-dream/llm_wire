//// Loopback consumer checks for nested deadlines and borrowed HTTP resources.

import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/time/duration
import http_gun
import http_gun/config
import http_gun/deadline
import http_gun/destination
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/message
import llm_wire/openai

@external(erlang, "retry_fixture", "endpoint")
fn endpoint() -> String

pub fn main() -> Nil {
  let assert Ok(client) =
    http_gun.start(
      config.default()
      |> config.with_destination(destination.loopback_only())
      |> config.with_request_timeout(config.After(duration.milliseconds(200))),
    )
  streaming_deadline(
    client,
    "/outer",
    1000,
    llm_wire.After(duration.seconds(5)),
  )
  wait_for_release(client, 200)
  streaming_deadline(client, "/own", 5000, llm_wire.After(duration.seconds(1)))
  wait_for_release(client, 200)
  streaming_deadline(client, "/infinite", 1000, llm_wire.Infinity)
  wait_for_release(client, 200)
  reported_usage_survives(client)
  wait_for_release(client, 200)
  default_timeout_is_replaced(client)
  wait_for_release(client, 200)
  // The original client has no expired view and remains usable.
  let assert Ok(llm_wire.Answer(text: "x", ..)) =
    llm_wire.run(
      client,
      prepare("/health", llm_wire.After(duration.seconds(5))),
    )
  http_gun.stop(client)
}

fn streaming_deadline(
  client: http_gun.Client,
  path: String,
  outer_ms: Int,
  own: llm_wire.Bound,
) -> Nil {
  let prepared = prepare(path, own)
  let outer = deadline.after(duration.milliseconds(outer_ms))
  let assert Ok(stream) =
    llm_wire.stream(http_gun.with_deadline(client, outer), prepared)
  // Accepted progress establishes that this is an active response, not an
  // admission timeout. The server keeps producing until the client closes.
  let assert Ok(llm_wire.Progress(_)) = llm_wire.next(stream)
  let assert Error(failure) = llm_wire.collect(stream)
  let assert error.DeadlineExceeded(error.WholeCall) = failure.error
  let assert llm_wire.MaybeSent = failure.sent
  let assert True = failure.partial_output
  let assert None = failure.usage
  Nil
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

fn prepare(path: String, own: llm_wire.Bound) -> llm_wire.Prepared(String) {
  let assert Ok(prepared) =
    llm_wire.prepare(
      openai.new("local-fixture")
        |> openai.config
        |> llm_wire.with_endpoint(endpoint() <> path)
        |> llm_wire.with_call_timeout(own)
        |> llm_wire.with_first_token_timeout(llm_wire.Infinity)
        |> llm_wire.with_idle_timeout(llm_wire.Infinity),
      llm_wire.request("fixture", [llm_wire.user("hi")]),
    )
  prepared
}

fn default_timeout_is_replaced(client: http_gun.Client) -> Nil {
  let prepared = prepare("/default", llm_wire.After(duration.seconds(5)))
  let assert Ok(stream) = llm_wire.stream(client, prepared)
  let assert Ok(llm_wire.Progress(_)) = llm_wire.next(stream)
  // The fixture holds completion behind a release request. Wait past the
  // 200ms client default before allowing completion; no short upper bound.
  process.sleep(300)
  let assert Ok(llm_wire.Answer(text: "x", ..)) =
    llm_wire.run(
      client,
      prepare("/release", llm_wire.After(duration.seconds(5))),
    )
  let assert Ok(llm_wire.Answer(text: "x", ..)) = llm_wire.collect(stream)
  Nil
}

fn reported_usage_survives(client: http_gun.Client) -> Nil {
  let assert Ok(prepared) =
    llm_wire.prepare(
      anthropic.new("local-fixture")
        |> anthropic.config
        |> llm_wire.with_endpoint(endpoint() <> "/usage")
        |> llm_wire.with_call_timeout(llm_wire.Infinity)
        |> llm_wire.with_first_token_timeout(llm_wire.Infinity)
        |> llm_wire.with_idle_timeout(llm_wire.Infinity),
      llm_wire.request("fixture", [llm_wire.user("hi")]),
    )
  let outer = deadline.after(duration.seconds(1))
  let assert Error(failure) =
    llm_wire.run(http_gun.with_deadline(client, outer), prepared)
  let assert error.DeadlineExceeded(error.WholeCall) = failure.error
  let assert llm_wire.MaybeSent = failure.sent
  let assert True = failure.partial_output
  let assert Some(message.Usage(4, 2, 6)) = failure.usage
  Nil
}
