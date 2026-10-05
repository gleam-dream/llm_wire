//// Independent nghttpd consumer; only public LLM Wire and HTTP Gun imports.

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun
import http_gun/config as http_config
import http_test_helpers
import llm_wire
import llm_wire/limit
import llm_wire/message
import llm_wire/provider
import simplifile

@external(erlang, "llm_wire_measure_ffi", "now")
fn now() -> Int

@external(erlang, "llm_wire_measure_ffi", "sample")
fn sample() -> #(Int, Int, Int, Int, Int, Int)

type Sample =
  #(Int, Int, Int, Int, Int, Int)

type Sampling {
  Finish(process.Subject(Sample))
}

fn peak(a: Sample, b: Sample) -> Sample {
  #(
    int.max(a.0, b.0),
    int.max(a.1, b.1),
    int.max(a.2, b.2),
    int.max(a.3, b.3),
    int.max(a.4, b.4),
    int.max(a.5, b.5),
  )
}

fn sampling(control: process.Subject(Sampling), maximum: Sample) -> Nil {
  let maximum = peak(maximum, sample())
  case process.receive(control, 10) {
    Ok(Finish(reply)) -> process.send(reply, maximum)
    Error(Nil) -> sampling(control, maximum)
  }
}

type Reply {
  Reply(text: String, done: Bool)
}

/// A minimal custom adapter for the local files: `text` events carry the
/// answer and `done` ends it.
fn adapter(endpoint: String, path: String) -> provider.Adapter {
  provider.new(
    message.Custom("local-gate"),
    endpoint,
    fn(request, _tools, _format) {
      Ok(provider.encoded(
        path,
        json.to_string(json.object([#("model", json.string(request.model))])),
      ))
    },
    fn() {
      provider.reducer(
        Reply("", False),
        fn(state, event) {
          case event.event {
            Some("text") ->
              Ok(
                #(Reply(..state, text: state.text <> event.data), [
                  message.TextDelta("0", event.data),
                ]),
              )
            Some("done") -> Ok(#(Reply(..state, done: True), []))
            _ -> Ok(#(state, []))
          }
        },
        fn(state) {
          case state.done {
            True -> Some(provider.text(state.text, None))
            False -> None
          }
        },
      )
    },
  )
}

fn prepared(endpoint: String, path: String) -> llm_wire.Prepared(String) {
  let settings =
    adapter(endpoint, path)
    |> provider.config
    |> llm_wire.with_limit(limit.TextBytesPerBlock, 4_194_304)
    |> llm_wire.with_call_timeout(llm_wire.After(duration.seconds(120)))
    |> llm_wire.with_first_token_timeout(llm_wire.After(duration.seconds(60)))
    |> llm_wire.with_idle_timeout(llm_wire.After(duration.seconds(60)))
  let assert Ok(call) =
    llm_wire.prepare(
      settings,
      llm_wire.request("synthetic-model", [llm_wire.user("hello")]),
    )
  call
}

fn hello() -> Result(llm_wire.Outcome(String), llm_wire.Failure) {
  Ok(llm_wire.Answer("hello", "hello", None))
}

fn batch(
  client: http_gun.Client,
  call: llm_wire.Prepared(String),
  n: Int,
) -> Nil {
  let ready = process.new_subject()
  let done = process.new_subject()
  // Every caller is alive and blocked on a barrier before releasing any request.
  list.each(list.repeat(Nil, n), fn(_) {
    let _ =
      process.spawn(fn() {
        let go = process.new_subject()
        process.send(ready, go)
        let assert Ok(Nil) = process.receive(go, 120_000)
        let start = now()
        let outcome = llm_wire.run(client, call)
        process.send(done, #(now() - start, outcome))
      })
    Nil
  })
  let gates =
    list.map(list.repeat(Nil, n), fn(_) {
      let assert Ok(go) = process.receive(ready, 120_000)
      go
    })
  let sampler_ready = process.new_subject()
  let _ =
    process.spawn(fn() {
      let control = process.new_subject()
      process.send(sampler_ready, control)
      sampling(control, sample())
    })
  let assert Ok(control) = process.receive(sampler_ready, 1000)
  let start = now()
  list.each(gates, fn(go) { process.send(go, Nil) })
  let outcomes =
    list.map(gates, fn(_) {
      let assert Ok(outcome) = process.receive(done, 120_000)
      outcome
    })
  let elapsed = now() - start
  let finish = process.new_subject()
  process.send(control, Finish(finish))
  let assert Ok(peak) = process.receive(finish, 1000)
  let failures = list.filter(outcomes, fn(pair) { pair.1 != hello() })
  let sorted = list.map(outcomes, fn(pair) { pair.0 }) |> list.sort(int.compare)
  let percentile = fn(p) {
    sorted
    |> list.drop(int.max(0, n * p / 100 - 1))
    |> list.first
    |> result.unwrap(0)
  }
  let assert Ok(stats) = http_gun.stats(client)
  io.println(
    json.to_string(
      json.object([
        #("scenario", json.string("simultaneous")),
        #("callers", json.int(n)),
        #("failures", json.int(list.length(failures))),
        #("elapsed_us", json.int(elapsed)),
        #("p50_us", json.int(percentile(50))),
        #("p95_us", json.int(percentile(95))),
        #("max_us", json.int(percentile(100))),
        #("connections", json.int(stats.connections)),
        #("vm_memory_peak_bytes", json.int(peak.0)),
        #("process_memory_peak_bytes", json.int(peak.1)),
        #("mailbox_total_peak", json.int(peak.2)),
        #("mailbox_single_peak", json.int(peak.3)),
        #("process_count_peak", json.int(peak.4)),
        #("ports_peak", json.int(peak.5)),
      ]),
    ),
  )
  let assert [] = failures
  Nil
}

pub fn main() -> Nil {
  let assert Ok(port) = simplifile.read("build/http-gun-local-port")
  let endpoint = "https://127.0.0.1:" <> string.trim(port)
  let policy =
    http_test_helpers.loopback_config()
    |> http_config.with_protocol(http_config.RequireHttp2)
    |> http_config.with_trust(http_config.CustomCa(
      "test/fixtures/llm-wire-test-ca.crt",
    ))
    |> http_config.with_max_connections(1)
    |> http_config.with_max_connections_per_origin(1)
    |> http_config.with_max_open_bodies(2048)
    |> http_config.with_max_queued_requests(2048)
    // The fixture advertises 8 streams and one remains occupied. A burst
    // of 1000 therefore needs 143 admission waves. At a 40 ms loopback ACK
    // cadence it cannot fit the ordinary 5 s pool timeout. Give this load
    // fixture an explicit bounded queue budget; production defaults and
    // timeout tests remain unchanged.
    |> http_config.with_pool_timeout(duration.seconds(30))
  let assert Ok(client) = http_gun.start(policy)
  let small = prepared(endpoint, "/small.sse")
  let long = prepared(endpoint, "/long.sse")
  let assert Ok(llm_wire.Answer(text: "hello", ..)) =
    llm_wire.run(client, small)
  let assert Ok(slow) = llm_wire.stream(client, long)
  let assert Ok(llm_wire.Progress(_)) = llm_wire.next(slow)
  let assert Ok(sibling) = llm_wire.stream(client, long)
  let assert Ok(llm_wire.Progress(_)) = llm_wire.next(sibling)
  // `close` answers `Closed` directly; it no longer returns a `Result`.
  let assert llm_wire.Closed = llm_wire.close(slow)
  let assert Ok(llm_wire.Answer(text:, ..)) = llm_wire.collect(sibling)
  let assert 2_097_152 = string.byte_size(text)
  io.println(
    "{\"scenario\":\"h2_cancel_sibling\",\"healthy_text_bytes\":2097152,\"cancelled\":true}",
  )
  let assert Ok(slow) = llm_wire.stream(client, long)
  let assert Ok(llm_wire.Progress(_)) = llm_wire.next(slow)
  list.each([1, 10, 100, 1000], fn(n) { batch(client, small, n) })
  let assert llm_wire.Closed = llm_wire.close(slow)
  let assert Ok(llm_wire.Answer(text: "hello", ..)) =
    llm_wire.run(client, small)
  http_gun.stop(client)
  Nil
}
