//// A sum type below the root of a structured output. OpenAI, Anthropic and
//// Gemini document `anyOf` of objects for structured output, so a Blueprint
//// union (`oneOf` of tagged objects) is sent as `anyOf` of strict objects
//// whose tag is a single-value `enum`; the reply is decoded by the original
//// codec. A union at the root, or one with a payload the provider's profile
//// does not admit, is refused with the typed schema error.

import gleam/json
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import http_test_helpers
import json/blueprint/codec
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/google
import llm_wire/message
import llm_wire/openai
import llm_wire/testing
import simplifile
import tool_fixtures

pub type Sources {
  NoSources
  Found(title: String, rank: Int)
}

fn sources() -> codec.Codec(Sources) {
  codec.union({
    use none <- codec.unit_variant("NoSources", NoSources)
    use found <- codec.variant(
      "Found",
      {
        use title <- codec.field("title", codec.string(), get: fn(s) { s.0 })
        use rank <- codec.field("rank", codec.int(), get: fn(s) { s.1 })
        codec.success(#(title, rank))
      },
      fn(pair: #(String, Int)) { Found(pair.0, pair.1) },
    )
    codec.match(fn(value) {
      case value {
        NoSources -> none
        Found(title, rank) -> found(#(title, rank))
      }
    })
  })
}

fn wires() -> List(#(String, message.Provider, llm_wire.Config)) {
  [
    #("openai", message.OpenAI, openai.new("test-key") |> openai.config),
    #(
      "anthropic",
      message.Anthropic,
      anthropic.new("test-key") |> anthropic.config,
    ),
    #("google", message.Google, google.new("test-key") |> google.config),
  ]
}

fn question(output: codec.Codec(o)) -> llm_wire.Request(o) {
  llm_wire.request("model-test", [llm_wire.user("Find sources")])
  |> llm_wire.with_output("sources", output)
}

fn answer_codec() -> codec.Codec(Sources) {
  tool_fixtures.one_field("answer", sources())
}

pub fn request_bodies_match_the_pinned_fixtures_test() {
  use #(name, _, config) <- list.each(wires())
  let assert Ok(prepared) = llm_wire.prepare(config, question(answer_codec()))
  let assert Ok(expected) =
    simplifile.read("test/fixtures/structured-union-" <> name <> ".request.txt")
  llm_wire.request_json(prepared) |> should.equal(string.trim(expected))
}

pub fn the_union_is_any_of_strict_objects_with_enum_tags_test() {
  use #(_, _, config) <- list.each(wires())
  let assert Ok(prepared) = llm_wire.prepare(config, question(answer_codec()))
  let body = llm_wire.request_json(prepared)
  string.contains(body, "\"anyOf\":[") |> should.be_true
  string.contains(body, "\"enum\":[\"Found\"]") |> should.be_true
  string.contains(body, "\"enum\":[\"NoSources\"]") |> should.be_true
  string.contains(body, "oneOf") |> should.be_false
  string.contains(body, "\"const\"") |> should.be_false
}

pub fn a_union_at_the_root_is_refused_in_every_wire_test() {
  use #(_, _, config) <- list.each(wires())
  llm_wire.prepare(config, question(sources()))
  |> should.equal(
    Error(error.UnsupportedSchema(
      error.Output,
      "Structured output requires an object root schema",
    )),
  )
}

pub fn a_union_in_a_list_item_is_accepted_test() {
  use #(_, _, config) <- list.each(wires())
  let output = tool_fixtures.one_field("answers", codec.list(sources()))
  let assert Ok(prepared) = llm_wire.prepare(config, question(output))
  string.contains(llm_wire.request_json(prepared), "\"anyOf\":[")
  |> should.be_true
}

/// The wires whose structured output is strict: Gemini's
/// `responseJsonSchema` also takes pairs and optional fields.
fn strict_wires() -> List(#(String, message.Provider, llm_wire.Config)) {
  list.filter(wires(), fn(wire) { wire.1 != message.Google })
}

pub fn a_union_payload_with_an_unsupported_schema_is_refused_test() {
  use #(_, _, config) <- list.each(strict_wires())
  let pairs =
    codec.union({
      use pair <- codec.variant(
        "Pair",
        codec.pair(codec.int(), codec.int()),
        fn(p: #(Int, Int)) { p },
      )
      codec.match(fn(p) { pair(p) })
    })
  let assert Error(error.UnsupportedSchema(error.Output, _)) =
    llm_wire.prepare(config, question(tool_fixtures.one_field("answer", pairs)))
}

pub fn an_optional_payload_field_is_still_refused_test() {
  use #(_, _, config) <- list.each(strict_wires())
  let loose =
    codec.union({
      use note <- codec.variant(
        "Note",
        {
          use text <- codec.optional_field("text", codec.string(), get: fn(t) {
            t
          })
          codec.success(text)
        },
        fn(t) { t },
      )
      codec.match(fn(t) { note(t) })
    })
  let assert Error(error.UnsupportedSchema(error.Output, reason)) =
    llm_wire.prepare(config, question(tool_fixtures.one_field("answer", loose)))
  string.contains(reason, "required") |> should.be_true
}

pub fn gemini_admits_a_pair_and_an_optional_field_in_a_payload_test() {
  let config = google.new("test-key") |> google.config
  let loose =
    codec.union({
      use point <- codec.variant(
        "Point",
        {
          use at <- codec.field(
            "at",
            codec.pair(codec.int(), codec.int()),
            get: fn(p: #(#(Int, Int), option.Option(String))) { p.0 },
          )
          use label <- codec.optional_field(
            "label",
            codec.string(),
            get: fn(p: #(#(Int, Int), option.Option(String))) { p.1 },
          )
          codec.success(#(at, label))
        },
        fn(p) { p },
      )
      codec.match(fn(p) { point(p) })
    })
  let assert Ok(prepared) =
    llm_wire.prepare(config, question(tool_fixtures.one_field("answer", loose)))
  let body = llm_wire.request_json(prepared)
  string.contains(body, "\"prefixItems\":[") |> should.be_true
  string.contains(body, "\"required\":[\"at\"]") |> should.be_true
}

fn run_text(
  provider: message.Provider,
  config: llm_wire.Config,
  text: String,
) -> Result(llm_wire.Outcome(Sources), llm_wire.Failure) {
  let assert Ok(prepared) = llm_wire.prepare(config, question(answer_codec()))
  http_test_helpers.run_reply(
    prepared,
    testing.events_for(provider, testing.text(text)),
  )
}

pub fn a_payload_variant_decodes_through_the_original_codec_test() {
  use #(_, provider, config) <- list.each(wires())
  let reply =
    "{\"answer\":{\"tag\":\"Found\",\"value\":{\"title\":\"t\",\"rank\":2}}}"
  let assert Ok(llm_wire.Answer(output:, text:, ..)) =
    run_text(provider, config, reply)
  output |> should.equal(Found("t", 2))
  text |> should.equal(reply)
}

pub fn a_unit_variant_decodes_through_the_original_codec_test() {
  use #(_, provider, config) <- list.each(wires())
  let assert Ok(llm_wire.Answer(output:, ..)) =
    run_text(provider, config, "{\"answer\":{\"tag\":\"NoSources\"}}")
  output |> should.equal(NoSources)
}

pub fn an_unknown_tag_is_invalid_output_in_every_wire_test() {
  use #(_, provider, config) <- list.each(wires())
  let reply =
    json.to_string(
      json.object([
        #("answer", json.object([#("tag", json.string("Other"))])),
      ]),
    )
  let assert Error(llm_wire.Failure(
    error: error.InvalidOutput(raw_output:, ..),
    ..,
  )) = run_text(provider, config, reply)
  raw_output |> should.equal(reply)
}
