//// Optional fields in structured output. OpenAI and Anthropic take a strict
//// schema in which every property is required, so an optional property is
//// sent as required and nullable. On the way back, a `null` for a property
//// whose own schema does not admit `null` is removed, recursively, before
//// the answer is validated and decoded; `Answer.text` is that cleaned JSON
//// (ADR 0021).

import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import http_test_helpers
import json/blueprint/codec
import json/blueprint/value
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/google
import llm_wire/internal/schema
import llm_wire/message
import llm_wire/openai
import llm_wire/testing

pub type Line {
  Line(sku: String, note: Option(String))
}

pub type Contact {
  /// `phone` is optional and nullable: absent, `null` or a string.
  Contact(email: Option(String), phone: Option(Option(String)))
}

pub type Source {
  Manual
  Scanned(page: Option(Int))
}

pub type Doc {
  Doc(
    title: Option(String),
    lines: List(Line),
    contact: Contact,
    source: Source,
  )
}

fn line() -> codec.Codec(Line) {
  use sku <- codec.field("sku", codec.string(), get: fn(l: Line) { l.sku })
  use note <- codec.optional_field("note", codec.string(), get: fn(l: Line) {
    l.note
  })
  codec.success(Line(sku:, note:))
}

fn contact() -> codec.Codec(Contact) {
  use email <- codec.optional_field(
    "email",
    codec.string(),
    get: fn(c: Contact) { c.email },
  )
  use phone <- codec.optional_field(
    "phone",
    codec.nullable(codec.string()),
    get: fn(c: Contact) { c.phone },
  )
  codec.success(Contact(email:, phone:))
}

fn page() -> codec.Codec(Option(Int)) {
  use page <- codec.optional_field("page", codec.int(), get: fn(p) { p })
  codec.success(page)
}

fn source() -> codec.Codec(Source) {
  codec.union({
    use manual <- codec.unit_variant("Manual", Manual)
    use scanned <- codec.variant("Scanned", page(), Scanned)
    codec.match(fn(item) {
      case item {
        Manual -> manual
        Scanned(page) -> scanned(page)
      }
    })
  })
}

fn doc() -> codec.Codec(Doc) {
  use title <- codec.optional_field("title", codec.string(), get: fn(d: Doc) {
    d.title
  })
  use lines <- codec.field("lines", codec.list(line()), get: fn(d: Doc) {
    d.lines
  })
  use contact <- codec.field("contact", contact(), get: fn(d: Doc) { d.contact })
  use source <- codec.field("source", source(), get: fn(d: Doc) { d.source })
  codec.success(Doc(title:, lines:, contact:, source:))
}

fn wires() -> List(#(message.Provider, llm_wire.Config)) {
  [
    #(message.OpenAI, openai.new("test-key") |> openai.config),
    #(message.Anthropic, anthropic.new("test-key") |> anthropic.config),
    #(message.Google, google.new("test-key") |> google.config),
  ]
}

fn strict_wires() -> List(#(message.Provider, llm_wire.Config)) {
  list.filter(wires(), fn(wire) { wire.0 != message.Google })
}

fn question() -> llm_wire.Request(Doc) {
  llm_wire.request("model-test", [llm_wire.user("Read the document")])
  |> llm_wire.with_output("doc", doc())
}

fn projected() -> value.Value {
  let assert Ok(schema) = codec.schema(doc())
  let assert Ok(projected) = schema.strict_output_schema(schema)
  let assert Ok(parsed) =
    value.parse(json.to_string(projected), value.default_limits())
  parsed
}

fn member(item: value.Value, name: String) -> value.Value {
  let assert value.Object(members) = item
  let assert Ok(found) = list.key_find(members, name)
  found
}

fn nullable_string() -> value.Value {
  value.Object([
    #(
      "anyOf",
      value.Array([
        value.Object([#("type", value.String("null"))]),
        value.Object([#("type", value.String("string"))]),
      ]),
    ),
  ])
}

fn names(items: List(String)) -> value.Value {
  value.Array(list.map(items, value.String))
}

pub fn an_optional_property_is_sent_required_and_nullable_test() {
  let root = projected()
  member(root, "required")
  |> should.equal(names(["title", "lines", "contact", "source"]))
  member(member(root, "properties"), "title") |> should.equal(nullable_string())
  member(root, "additionalProperties") |> should.equal(value.Bool(False))
}

pub fn optional_properties_in_nested_objects_and_list_items_test() {
  let properties = member(projected(), "properties")
  let item = member(member(properties, "lines"), "items")
  member(item, "required") |> should.equal(names(["sku", "note"]))
  member(member(item, "properties"), "note") |> should.equal(nullable_string())
  let contact = member(properties, "contact")
  member(contact, "required") |> should.equal(names(["email", "phone"]))
}

pub fn a_nullable_optional_property_is_not_wrapped_twice_test() {
  let contact = member(member(projected(), "properties"), "contact")
  member(member(contact, "properties"), "phone")
  |> should.equal(nullable_string())
}

pub fn an_optional_property_in_a_union_payload_test() {
  let assert value.Array([_, scanned]) =
    member(member(member(projected(), "properties"), "source"), "anyOf")
  let payload = member(member(scanned, "properties"), "value")
  member(payload, "required") |> should.equal(names(["page"]))
  member(member(payload, "properties"), "page")
  |> should.equal(
    value.Object([
      #(
        "anyOf",
        value.Array([
          value.Object([#("type", value.String("null"))]),
          value.Object([#("type", value.String("integer"))]),
        ]),
      ),
    ]),
  )
}

pub fn strict_wires_prepare_a_codec_with_optional_fields_test() {
  use #(_, config) <- list.each(strict_wires())
  let assert Ok(prepared) = llm_wire.prepare(config, question())
  llm_wire.request_json(prepared)
  |> string.contains(
    "\"required\":[\"title\",\"lines\",\"contact\",\"source\"]",
  )
  |> should.be_true
}

pub fn google_keeps_optional_properties_optional_test() {
  let assert Ok(prepared) =
    llm_wire.prepare(google.new("test-key") |> google.config, question())
  let body = llm_wire.request_json(prepared)
  string.contains(body, "\"required\":[\"lines\",\"contact\",\"source\"]")
  |> should.be_true
  string.contains(body, "\"title\":{\"type\":\"string\"}") |> should.be_true
}

fn run(
  provider: message.Provider,
  config: llm_wire.Config,
  reply: String,
) -> Result(llm_wire.Outcome(Doc), llm_wire.Failure) {
  let assert Ok(prepared) = llm_wire.prepare(config, question())
  http_test_helpers.run_reply(
    prepared,
    testing.events_for(provider, testing.text(reply)),
  )
}

const nulls_reply =
  "{\"title\":null,\"lines\":[{\"sku\":\"a\",\"note\":null},{\"sku\":\"b\",\"note\":\"x\"}],\"contact\":{\"email\":null,\"phone\":null},\"source\":{\"tag\":\"Scanned\",\"value\":{\"page\":null}}}"

pub fn nulls_for_optional_properties_are_removed_before_decoding_test() {
  use #(provider, config) <- list.each(wires())
  let assert Ok(llm_wire.Answer(output:, text:, ..)) =
    run(provider, config, nulls_reply)
  output
  |> should.equal(Doc(
    title: None,
    lines: [Line("a", None), Line("b", Some("x"))],
    contact: Contact(email: None, phone: Some(None)),
    source: Scanned(None),
  ))
  text
  |> should.equal(
    "{\"lines\":[{\"sku\":\"a\"},{\"sku\":\"b\",\"note\":\"x\"}],\"contact\":{\"phone\":null},\"source\":{\"tag\":\"Scanned\",\"value\":{}}}",
  )
}

pub fn the_cleaned_text_decodes_with_the_original_codec_test() {
  use #(provider, config) <- list.each(wires())
  let assert Ok(llm_wire.Answer(output:, text:, ..)) =
    run(provider, config, nulls_reply)
  codec.decode_json(doc(), text) |> should.equal(Ok(output))
}

pub fn an_answer_without_removable_nulls_keeps_its_text_test() {
  use #(provider, config) <- list.each(wires())
  let reply =
    "{ \"title\": \"T\", \"lines\": [], \"contact\": {\"phone\": null}, \"source\": {\"tag\": \"Manual\"} }"
  let assert Ok(llm_wire.Answer(output:, text:, ..)) =
    run(provider, config, reply)
  text |> should.equal(reply)
  output
  |> should.equal(Doc(Some("T"), [], Contact(None, Some(None)), Manual))
}

pub fn a_null_for_a_required_property_stays_invalid_output_test() {
  use #(provider, config) <- list.each(wires())
  let reply = "{\"lines\":null,\"contact\":{},\"source\":{\"tag\":\"Manual\"}}"
  let assert Error(llm_wire.Failure(
    error: error.InvalidOutput(raw_output:, ..),
    ..,
  )) = run(provider, config, reply)
  raw_output |> should.equal(reply)
}

pub fn invalid_output_keeps_the_raw_text_after_a_removal_test() {
  use #(provider, config) <- list.each(wires())
  let reply =
    "{\"title\":null,\"lines\":[{\"sku\":1}],\"contact\":{},\"source\":{\"tag\":\"Manual\"}}"
  let assert Error(llm_wire.Failure(
    error: error.InvalidOutput(raw_output:, ..),
    ..,
  )) = run(provider, config, reply)
  raw_output |> should.equal(reply)
}

pub fn an_optional_any_property_keeps_its_null_test() {
  let output = {
    use extra <- codec.optional_field("extra", codec.value(), get: fn(e) { e })
    codec.success(extra)
  }
  let assert Ok(prepared) =
    llm_wire.prepare(
      google.new("test-key") |> google.config,
      llm_wire.request("model-test", [llm_wire.user("x")])
        |> llm_wire.with_output("extra", output),
    )
  let assert Ok(llm_wire.Answer(output:, text:, ..)) =
    http_test_helpers.run_reply(
      prepared,
      testing.events_for(message.Google, testing.text("{\"extra\":null}")),
    )
  output |> should.equal(Some(value.Null))
  text |> should.equal("{\"extra\":null}")
}
