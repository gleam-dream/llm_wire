//// Credentials never appear in `string.inspect` output of a value that holds
//// or produced them: provider options, configurations, custom adapters,
//// prepared calls, open streams, failures, telemetry metadata and recorded
//// cassettes. The `reveal_*` accessors are gone; the credential reaches
//// only the outgoing request.

import fake_server
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/cassette
import http_gun/testing as http_testing
import http_test_helpers
import json/blueprint/codec
import llm_wire
import llm_wire/anthropic
import llm_wire/google
import llm_wire/internal/api
import llm_wire/internal/call
import llm_wire/message
import llm_wire/openai
import llm_wire/provider
import llm_wire/telemetry
import llm_wire/testing
import simplifile
import sinal
import tool_fixtures

const secret = "sk-secret-redaction-0123456789"

fn padded() -> String {
  "  " <> secret <> "  "
}

fn request() -> llm_wire.Request(String) {
  llm_wire.request("model-x", [llm_wire.user("Hi")])
}

fn hidden(value: a) -> Nil {
  string.contains(string.inspect(value), secret) |> should.be_false
}

fn openai_options() -> openai.Options {
  openai.new(padded())
  |> openai.with_organization("org")
  |> openai.with_project("proj")
}

fn anthropic_options() -> anthropic.Options {
  anthropic.new(padded()) |> anthropic.with_version("v")
}

fn google_options() -> google.Options {
  google.new(padded()) |> google.with_api_version("v1")
}

type CustomState {
  CustomState(text: String, done: Bool)
}

/// A custom adapter whose credential lives only in its header closure.
fn custom_adapter() -> provider.Adapter {
  let key = padded() |> string.trim
  provider.new(
    message.Custom("custom"),
    "https://custom.llm-wire.invalid",
    fn(request: provider.Request, _tools, _format) {
      Ok(provider.encoded(
        "/custom",
        json.to_string(json.object([#("model", json.string(request.model))])),
      ))
    },
    fn() {
      provider.reducer(
        CustomState("", False),
        fn(state: CustomState, event: provider.Event) {
          case event.event {
            Some("text") ->
              Ok(
                #(CustomState(..state, text: state.text <> event.data), [
                  message.TextDelta("0", event.data),
                ]),
              )
            Some("done") -> Ok(#(CustomState(..state, done: True), []))
            _ -> Ok(#(state, []))
          }
        },
        fn(state: CustomState) {
          case state.done {
            True -> Some(provider.text(state.text, None))
            False -> None
          }
        },
      )
    },
  )
  |> provider.with_headers(fn() { [#("authorization", "Bearer " <> key)] })
}

/// Each configuration, its provider and the events of a text answer on its
/// wire.
fn configs() -> List(#(message.Provider, llm_wire.Config, List(String))) {
  let lowered = fn(provider) {
    let chunks =
      testing.chunks(testing.events_for(provider, testing.text("ok")))
    chunks
  }
  [
    #(message.OpenAI, openai.config(openai_options()), lowered(message.OpenAI)),
    #(
      message.Anthropic,
      anthropic.config(anthropic_options()),
      lowered(message.Anthropic),
    ),
    #(message.Google, google.config(google_options()), lowered(message.Google)),
    #(message.Custom("custom"), provider.config(custom_adapter()), [
      "event: text\ndata: ok\n\n",
      "event: done\ndata: end\n\n",
    ]),
  ]
}

pub fn provider_options_do_not_print_the_key_test() {
  hidden(openai_options())
  hidden(anthropic_options())
  hidden(google_options())
}

pub fn configs_and_adapters_do_not_print_the_key_test() {
  list.each(configs(), fn(entry) {
    hidden(entry.1)
    hidden(llm_wire.with_endpoint(entry.1, "https://proxy.example.test/v1"))
  })
}

pub fn custom_adapter_does_not_print_the_key_test() {
  hidden(custom_adapter())
  hidden(provider.config(custom_adapter()))
}

/// Was `reveal_headers`: the credential reaches only the outgoing request,
/// trimmed, under each provider's header.
pub fn the_credential_reaches_only_the_outgoing_request_test() {
  let expected = [
    #("authorization", "Bearer " <> secret),
    #("x-api-key", secret),
    #("x-goog-api-key", secret),
    #("authorization", "Bearer " <> secret),
  ]
  list.zip(configs(), expected)
  |> list.each(fn(pair) {
    let #(#(_, config, _), header) = pair
    let assert Ok(prepared) = llm_wire.prepare(config, request())
    api.http_request(call.prepared_call(prepared)).headers
    |> list.contains(header)
    |> should.be_true
    string.contains(llm_wire.request_json(prepared), secret)
    |> should.be_false
  })
}

pub fn prepared_calls_do_not_print_the_key_test() {
  list.each(configs(), fn(entry) {
    let assert Ok(prepared) = llm_wire.prepare(entry.1, request())
    hidden(prepared)
    let assert Ok(structured) =
      llm_wire.prepare(
        entry.1,
        request()
          |> llm_wire.with_output(
            "answer",
            tool_fixtures.one_field("answer", codec.int()),
          ),
      )
    hidden(structured)
  })
}

pub fn streams_and_fixture_exchanges_do_not_print_the_key_test() {
  use #(provider, config, _) <- list.each(configs())
  let assert Ok(prepared) = llm_wire.prepare(config, request())
  let exchange =
    testing.exchange(prepared, testing.events_for(provider, testing.text("hi")))
  hidden(exchange)
  string.contains(cassette.encode(http_testing.script([exchange])), secret)
  |> should.be_false
  use client <- http_test_helpers.with_script([exchange])
  let assert Ok(stream) = llm_wire.stream(client, prepared)
  hidden(stream)
  let _ = llm_wire.close(stream)
  Nil
}

pub fn failures_do_not_print_the_key_test() {
  use #(provider, config, _) <- list.each(configs())
  let assert Ok(prepared) = llm_wire.prepare(config, request())
  let assert Error(status) =
    http_test_helpers.run_reply(
      prepared,
      testing.http_status(message.Custom("scripted"), 401, "unauthorized"),
    )
  hidden(status)
  hidden(llm_wire.describe_failure(status))
  let assert Error(interrupted) =
    http_test_helpers.run_reply(
      prepared,
      testing.interrupted(testing.events([])),
    )
  hidden(interrupted)
  // A request that matches no scripted exchange.
  let assert Ok(other) =
    llm_wire.prepare(config, llm_wire.request("other", [llm_wire.user("x")]))
  use client <- http_test_helpers.with_script([
    testing.exchange(prepared, testing.events_for(provider, testing.text("x"))),
  ])
  let assert Error(mismatch) = llm_wire.run(client, other)
  hidden(mismatch)
}

pub fn telemetry_metadata_does_not_print_the_key_test() {
  let subject = process.new_subject()
  let attachment =
    sinal.observe(telemetry.event(), fn(_, meta: telemetry.Metadata) {
      process.send(subject, meta)
    })
  list.each(configs(), fn(entry) {
    let #(provider, config, _) = entry
    let assert Ok(prepared) = llm_wire.prepare(config, request())
    let _ =
      http_test_helpers.run_reply(
        prepared,
        testing.events_for(provider, testing.text("ok")),
      )
    Nil
  })
  let events = drain(subject, [])
  let _ = sinal.detach(attachment)
  { events != [] } |> should.be_true
  hidden(events)
}

fn drain(
  subject: process.Subject(telemetry.Metadata),
  acc: List(telemetry.Metadata),
) -> List(telemetry.Metadata) {
  case process.receive(subject, 50) {
    Ok(meta) -> drain(subject, [meta, ..acc])
    Error(Nil) -> list.reverse(acc)
  }
}

@external(erlang, "erlang", "unique_integer")
fn unique_integer() -> Int

/// A live recording of every provider's request never stores the key.
pub fn recorded_cassettes_do_not_store_the_key_test() {
  let assert Ok(server) = fake_server.start()
  let entries = configs()
  let _ =
    process.spawn_unlinked(fn() {
      list.each(entries, fn(entry) {
        let assert Ok(socket) = fake_server.accept_connection(server, 5000)
        let assert Ok(_) = fake_server.read_request_headers(socket, 5000)
        let _ =
          fake_server.send_sse_stream(
            socket,
            list.map(entry.2, fn(chunk) { #(0, bit_array.from_string(chunk)) }),
            True,
          )
        Nil
      })
    })
  let destination =
    "/tmp/llm-wire-redaction-"
    <> int.to_string(int.absolute_value(unique_integer()))
    <> ".json"
  let assert Ok(recorded) =
    cassette.record(
      http_test_helpers.loopback_config(),
      destination,
      cassette.options(),
    )
  list.each(entries, fn(entry) {
    let config =
      llm_wire.with_endpoint(
        entry.1,
        "http://127.0.0.1:" <> int.to_string(server.port),
      )
    let assert Ok(prepared) = llm_wire.prepare(config, request())
    let assert Ok(llm_wire.Answer(text: "ok", ..)) =
      llm_wire.run(recorded.client, prepared)
    Nil
  })
  cassette.finish(recorded.recording, duration.seconds(5))
  |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  fake_server.stop(server)
  let assert Ok(stored) = simplifile.read(destination)
  string.contains(stored, secret) |> should.be_false
  // The recording holds every provider's request.
  string.contains(stored, "custom.llm-wire.invalid") |> should.be_false
  list.length(string.split(stored, "\"request\"")) |> should.equal(5)
  let assert Ok(Nil) = simplifile.delete(destination)
}
