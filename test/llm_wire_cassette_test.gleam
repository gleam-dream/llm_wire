//// LLM calls use HTTP Gun's sole binary fixture schema and offline client.

import gleam/bit_array
import gleam/http
import gleam/http/request as http_request
import gleam/http/response
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import http_gun
import http_gun/cassette
import http_gun/config as http_config
import http_gun/error
import http_gun/redaction
import http_gun/testing as http_testing
import http_test_helpers
import llm_wire/config
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/testing
import llm_wire/types
import simplifile

fn settings() -> config.Config {
  let assert Ok(key) = types.api_key("synthetic-cassette-secret")
  config.openai(openai.options(key))
}

fn prepared(text: String) -> session.PreparedCall {
  let assert Ok(model) = types.model_id("cassette-model")
  let assert Ok(call) =
    session.prepare(
      settings(),
      types.new_request(model, [types.UserMessage(text)]),
    )
  call
}

fn reply(text: String) -> testing.Reply {
  testing.Events([
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n",
    "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"item\",\"delta\":\""
      <> text
      <> "\"}\n\n",
    "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n",
    "event: response.completed\ndata: {\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}\n\n",
  ])
}

fn encoded() -> String {
  cassette.encode(
    http_testing.script([testing.exchange(prepared("Hello"), reply("loaded"))]),
  )
}

pub fn identical_requests_consume_distinct_replies_in_order_test() {
  let call = prepared("Hello")
  use client <- http_test_helpers.with_script([
    testing.exchange(call, reply("first")),
    testing.exchange(call, reply("second")),
  ])
  session.run(client, call) |> should.equal(Ok(session.RunText("first", None)))
  session.run(client, call) |> should.equal(Ok(session.RunText("second", None)))
  let assert Error(session.RunFailure(
    types.HttpFailure(error.PlaybackExhausted),
    evidence,
  )) = session.run(client, call)
  evidence |> should.equal(types.initial_retry_evidence())
}

pub fn mismatches_do_not_consume_the_expected_exchange_test() {
  let call = prepared("Hello")
  use client <- http_test_helpers.with_script([
    testing.exchange(call, reply("correct")),
  ])
  let assert Error(session.RunFailure(
    types.HttpFailure(error.PlaybackMismatch(0)),
    evidence,
  )) = session.run(client, prepared("Wrong"))
  evidence |> should.equal(types.initial_retry_evidence())
  session.run(client, call)
  |> should.equal(Ok(session.RunText("correct", None)))
}

pub fn cassette_json_round_trip_drives_the_same_public_flow_test() {
  let assert Ok(tape) = cassette.parse(encoded(), 100_000)
  let assert Ok(client) = http_testing.playback(tape, http_config.default())
  session.run(client, prepared("Hello"))
  |> should.equal(Ok(session.RunText("loaded", None)))
  http_gun.stop(client)
  string.contains(encoded(), "synthetic-cassette-secret") |> should.be_false
  string.contains(encoded(), "content-type") |> should.be_true
}

pub fn disk_fixtures_replace_only_the_transport_test() {
  let assert Ok(tape) =
    cassette.load("test/fixtures/http-gun-text.json", 100_000)
  let assert Ok(client) = http_testing.playback(tape, http_config.default())
  session.run(client, prepared("Hello"))
  |> should.equal(Ok(session.RunText("loaded", None)))
  http_gun.stop(client)
}

pub fn malformed_and_incompatible_cassettes_fail_explicitly_test() {
  cassette.parse("{", 100) |> should.equal(Error(cassette.Corrupt))
  cassette.parse("{\"http_gun\":99,\"exchanges\":[]}", 100)
  |> should.equal(Error(cassette.UnsupportedVersion(99)))
  cassette.parse("{\"version\":1,\"exchanges\":[]}", 100) |> should.be_error
  cassette.load("/private/tmp/llm-wire-fixture-does-not-exist", 100)
  |> should.equal(Error(cassette.Missing))
}

pub fn byte_bounds_apply_to_parse_and_disk_load_test() {
  let raw = encoded()
  let bytes = string.byte_size(raw)
  cassette.parse(raw, bytes) |> should.be_ok
  cassette.parse(raw, bytes - 1)
  |> should.equal(Error(cassette.TooLarge(bytes - 1, bytes)))
  cassette.load("test/fixtures/http-gun-text.json", 5)
  |> should.equal(Error(cassette.TooLarge(5, 6)))
  cassette.parse(raw, -1) |> should.be_error
}

pub fn binary_chunks_preserve_split_utf8_and_crlf_test() {
  let call = prepared("Hello")
  let original = testing.exchange(call, reply("héllo"))
  let assert http_testing.Respond(response, ending) =
    http_testing.reply(original)
  let bytes = bit_array.concat(response.body)
  let chunks = byte_chunks(bytes)
  let exchange =
    http_testing.exchange(
      http_testing.request(original),
      http_testing.Respond(response.set_body(response, chunks), ending),
    )
  let assert Ok(parsed) =
    cassette.parse(cassette.encode(http_testing.script([exchange])), 100_000)
  let assert Ok(client) = http_testing.playback(parsed, http_config.default())
  session.run(client, call) |> should.equal(Ok(session.RunText("héllo", None)))
  http_gun.stop(client)
}

pub fn cassette_construction_rejects_invalid_status_and_bit_arrays_test() {
  let request =
    http_testing.request(testing.exchange(prepared("Hello"), reply("x")))
  http_testing.script([
    http_testing.exchange(
      request,
      http_testing.Respond(
        response.new(99) |> response.set_body([]),
        http_testing.Finished([]),
      ),
    ),
  ])
  |> http_testing.playback(http_config.default())
  |> should.equal(Error(http_gun.InvalidScript(0)))
  http_testing.script([
    http_testing.exchange(
      http_request.set_body(request, <<1:1>>),
      http_testing.Reject(error.new(error.ClientClosed, error.NotSent)),
    ),
  ])
  |> http_testing.playback(http_config.default())
  |> should.equal(Error(http_gun.InvalidScript(0)))
}

pub fn recorded_status_and_interruption_keep_normal_error_evidence_test() {
  let call = prepared("Hello")
  use client <- http_test_helpers.with_script([
    testing.exchange(call, testing.Status(429, "busy")),
    testing.exchange(call, testing.Interrupted([])),
  ])
  let assert Error(session.RunFailure(
    types.HttpStatusError(429, "busy", None),
    retry,
  )) = session.run(client, call)
  retry.response_bytes_observed |> should.be_true
  let assert Error(session.RunFailure(
    types.HttpFailure(error.RequestFailed(error.PeerClosed)),
    retry,
  )) = session.run(client, call)
  retry.response_bytes_observed |> should.be_false
  retry.classification |> should.equal(types.RequestMayHaveReachedProvider)
}

pub fn required_schema_fields_and_tags_are_checked_test() {
  let raw = encoded()
  list.each(
    [
      "method",
      "url",
      "headers",
      "body",
      "text",
      "chunks",
      "status",
      "ending",
    ],
    fn(field) {
      cassette.parse(
        string.replace(raw, "\"" <> field <> "\":", "\"missing\":"),
        100_000,
      )
      |> should.be_error
    },
  )
  cassette.parse(string.replace(raw, "\"response\"", "\"unknown\""), 100_000)
  |> should.be_error
}

pub fn invalid_utf8_file_is_a_typed_failure_test() {
  let path = "/private/tmp/llm-wire-invalid-utf8-fixture"
  let assert Ok(Nil) = simplifile.write_bits(path, <<255, 0>>)
  cassette.load(path, 2) |> should.equal(Error(cassette.Corrupt))
  let assert Ok(Nil) = simplifile.delete(path)
}

pub fn significant_headers_must_match_and_credentials_are_excluded_test() {
  let call = prepared("Hello")
  let expected = testing.exchange(call, reply("matched"))
  let expected_request = http_testing.request(expected)
  let wrong =
    http_testing.exchange(
      http_request.set_header(expected_request, "openai-project", "significant"),
      http_testing.reply(expected),
    )
  use client <- http_test_helpers.with_script([wrong])
  let assert Error(session.RunFailure(
    types.HttpFailure(error.PlaybackMismatch(_)),
    _,
  )) = session.run(client, call)
  // Matching is exact for significant headers; excluded credentials don't alter it.
  let key = http_testing.match_key(redaction.default(), _)
  key(expected_request)
  |> should.equal(
    key(http_request.set_header(
      expected_request,
      "authorization",
      "Bearer different",
    )),
  )
  key(expected_request)
  |> should.not_equal(key(
    http_request.Request(..expected_request, method: http.Get),
  ))
}

pub fn replayed_partial_stream_preserves_interruption_evidence_test() {
  let call = prepared("Hello")
  let assert testing.Events(chunks) = reply("partial")
  use client <- http_test_helpers.with_script([
    testing.exchange(call, testing.Interrupted(list.take(chunks, 2))),
  ])
  let assert Error(session.RunFailure(_, retry)) = session.run(client, call)
  retry.response_bytes_observed |> should.be_true
  retry.semantic_progress_observed |> should.be_true
}

pub fn unexpected_success_statuses_match_the_http_transport_test() {
  let call = prepared("Hello")
  use client <- http_test_helpers.with_script([
    testing.exchange(call, testing.Status(201, "created")),
  ])
  let assert Error(session.RunFailure(
    types.HttpStatusError(201, "created", _),
    _,
  )) = session.run(client, call)
}

// Explicit fixture regeneration; never record-if-missing during tests.
pub fn main() {
  let assert Ok(Nil) =
    simplifile.write("test/fixtures/http-gun-text.json", encoded())
}

fn byte_chunks(bytes: BitArray) -> List(BitArray) {
  case bytes {
    <<byte, rest:bytes>> -> [<<byte>>, ..byte_chunks(rest)]
    <<>> -> []
    _ -> panic as "Fixture must contain whole bytes"
  }
}
