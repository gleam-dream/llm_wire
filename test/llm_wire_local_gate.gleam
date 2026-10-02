//// Independent nghttpd consumer; only public LLM Wire and HTTP Gun imports.

import external_provider
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string
import http_gun
import http_gun/config as http_config
import http_test_helpers
import llm_wire/config
import llm_wire/provider
import llm_wire/session
import llm_wire/types
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

fn prepared(endpoint: types.Endpoint, path: String) -> session.PreparedCall {
  let base = external_provider.adapter(endpoint)
  let adapter =
    provider.adapter(
      provider.Spec(
        identity: provider.identity(base),
        endpoint: endpoint,
        headers: fn() { provider.reveal_headers(base) },
        encode: fn(request, tools, format) {
          provider.encode(base, request, tools, format)
          |> result.map(fn(encoded) {
            provider.EncodedRequest(path, encoded.body)
          })
        },
        project_tool_schema: fn(schema) {
          provider.project_tool_schema(base, schema)
        },
        project_output_schema: fn(schema) {
          provider.project_output_schema(base, schema)
        },
        new_reducer: fn(limits, tools) {
          provider.new_reducer(base, limits, tools)
        },
      ),
    )
  let settings =
    config.from_provider(adapter)
    |> config.with_limits(
      types.Limits(
        ..types.default_limits(),
        text_bytes_per_block_limit: 4_194_304,
      ),
    )
    |> config.with_deadlines(
      types.Deadlines(
        ..types.default_deadlines(),
        overall_timeout_ms: 120_000,
        idle_timeout_ms: 60_000,
      ),
    )
  let assert Ok(model) = types.model_id("synthetic-model")
  let assert Ok(call) =
    session.prepare(
      settings,
      types.new_request(model, [types.UserMessage("hello")]),
    )
  call
}

fn batch(client: http_gun.Client, call: session.PreparedCall, n: Int) -> Nil {
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
        let outcome = session.run(client, call)
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
  let failures =
    list.filter(outcomes, fn(pair) {
      pair.1 != Ok(session.RunText("hello", None))
    })
  let sorted = list.map(outcomes, fn(pair) { pair.0 }) |> list.sort(int.compare)
  let percentile = fn(p) {
    sorted
    |> list.drop(int.max(0, n * p / 100 - 1))
    |> list.first
    |> result.unwrap(0)
  }
  let assert Ok(stats) = http_gun.snapshot(client)
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
  let assert Ok(endpoint) =
    types.endpoint("https://127.0.0.1:" <> string.trim(port))
  let defaults = http_test_helpers.loopback_config()
  let policy =
    http_config.Config(
      ..defaults,
      protocol: http_config.RequireHttp2,
      trust: http_config.CustomCa("test/fixtures/llm-wire-test-ca.crt"),
      deadline_ms: 120_000,
      limits: http_config.Limits(
        ..defaults.limits,
        connections: 1,
        per_origin: 1,
        active: 2048,
        waiting: 2048,
      ),
    )
  let assert Ok(client) = http_gun.start(policy)
  let small = prepared(endpoint, "/small.sse")
  let long = prepared(endpoint, "/long.sse")
  let assert Ok(session.RunText("hello", _)) = session.run(client, small)
  let assert Ok(slow) = session.stream(client, long)
  let assert Ok(session.NextProgress(_)) = session.next(slow)
  let assert Ok(sibling) = session.stream(client, long)
  let assert Ok(session.NextProgress(_)) = session.next(sibling)
  let assert Ok(types.ConsumerClosed) = session.close(slow)
  let assert Ok(session.RunText(text, _)) = session.collect(sibling)
  let assert 2_097_152 = string.byte_size(text)
  io.println(
    "{\"scenario\":\"h2_cancel_sibling\",\"healthy_text_bytes\":2097152,\"cancelled\":true}",
  )
  let assert Ok(slow) = session.stream(client, long)
  let assert Ok(session.NextProgress(_)) = session.next(slow)
  list.each([1, 10, 100, 1000], fn(n) { batch(client, small, n) })
  let assert Ok(types.ConsumerClosed) = session.close(slow)
  let assert Ok(session.RunText("hello", _)) = session.run(client, small)
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}
