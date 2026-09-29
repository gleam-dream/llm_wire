import gleam/bit_array
import gleam/erlang/atom
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import llm_wire/cassette
import llm_wire/config
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/testing
import llm_wire/types

fn settings() -> config.Config {
  let assert Ok(key) = types.api_key("offline-test-key")
  config.openai(openai.options(key))
}

fn request() -> types.Request {
  let assert Ok(model) = types.model_id("cassette-model")
  types.new_request(model, [types.UserMessage("Hello")])
}

fn response(text: String) -> testing.Reply {
  testing.Events([
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n",
    "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"item\",\"delta\":\""
      <> text
      <> "\"}\n\n",
    "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\n\n",
    "event: response.completed\ndata: {\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}\n\n",
  ])
}

pub fn identical_requests_consume_distinct_replies_in_order_test() {
  let assert Ok(prepared) = session.prepare(settings(), request())
  let expected =
    testing.ExpectedRequest(
      method: "POST",
      endpoint: "https://api.openai.com/v1",
      path: "/v1/responses",
      body: session.prepared_request_json(prepared),
    )
  let script =
    testing.start_matched([
      testing.Exchange(expected, response("first")),
      testing.Exchange(expected, response("second")),
    ])
  let assert Ok(prepared) =
    session.prepare(testing.with_script(settings(), script), request())
  session.run(prepared) |> should.equal(Ok(session.RunText("first", None)))
  session.run(prepared) |> should.equal(Ok(session.RunText("second", None)))
  testing.remaining(script) |> should.equal(0)
  let assert Error(session.RunFailure(types.ConfigurationError(_), _)) =
    session.run(prepared)
}

pub fn mismatches_do_not_consume_the_expected_exchange_test() {
  let assert Ok(prepared) = session.prepare(settings(), request())
  let expected =
    testing.ExpectedRequest(
      "POST",
      "https://api.openai.com/v1",
      "/v1/responses",
      session.prepared_request_json(prepared),
    )
  list.each(
    [
      testing.ExpectedRequest(..expected, method: "GET"),
      testing.ExpectedRequest(
        ..expected,
        endpoint: "https://elsewhere.invalid/v1",
      ),
      testing.ExpectedRequest(..expected, path: "/different"),
      testing.ExpectedRequest(..expected, body: "{}"),
    ],
    fn(wrong) {
      let script =
        testing.start_matched([testing.Exchange(wrong, response("unused"))])
      let assert Ok(prepared) =
        session.prepare(testing.with_script(settings(), script), request())
      let assert Error(session.RunFailure(types.ConfigurationError(_), retry)) =
        session.run(prepared)
      retry.classification |> should.equal(types.NoRequestSent)
      testing.remaining(script) |> should.equal(1)
      list.length(testing.requests(script)) |> should.equal(1)
    },
  )
}

pub fn cassette_json_round_trip_drives_the_same_public_flow_test() {
  let assert Ok(prepared) = session.prepare(settings(), request())
  let expected =
    testing.ExpectedRequest(
      "POST",
      "https://api.openai.com/v1",
      "/v1/responses",
      session.prepared_request_json(prepared),
    )
  let assert Ok(recording) =
    cassette.new([
      testing.Exchange(expected, response("loaded")),
    ])
  let assert Ok(saved) = cassette.to_json(recording, 100_000)
  let assert Ok(cassette) = cassette.parse(saved, 100_000)
  let script = cassette.start(cassette)
  let assert Ok(prepared) =
    session.prepare(testing.with_script(settings(), script), request())
  session.run(prepared) |> should.equal(Ok(session.RunText("loaded", None)))
}

pub fn disk_fixtures_replace_only_the_transport_test() {
  list.each(
    [
      #("hello", "Hello", "first fixture"),
      #("next", "Next", "second fixture"),
    ],
    fn(example) {
      let #(name, prompt, answer) = example
      let assert Ok(recording) =
        cassette.load("test/fixtures/cassette/" <> name <> ".json", 10_000)
      let script = cassette.start(recording)
      let request =
        types.Request(..request(), messages: [types.UserMessage(prompt)])
      let assert Ok(prepared) =
        session.prepare(testing.with_script(settings(), script), request)
      session.run(prepared) |> should.equal(Ok(session.RunText(answer, None)))
      testing.remaining(script) |> should.equal(0)
    },
  )
}

pub fn malformed_and_incompatible_cassettes_fail_explicitly_test() {
  list.each(
    [
      "not json", "{}", "{\"version\":\"1\",\"exchanges\":[]}",
      "{\"version\":1}", "{\"version\":1,\"exchanges\":null}",
      "{\"version\":1,\"exchanges\":[{}]}",
    ],
    fn(raw) {
      cassette.parse(raw, 100_000) |> should.equal(Error(cassette.InvalidJson))
    },
  )
  cassette.parse("{\"version\":2,\"exchanges\":[]}", 100_000)
  |> should.equal(Error(cassette.UnsupportedVersion(2)))
}

pub fn byte_bounds_apply_to_parse_save_and_disk_load_test() {
  let raw = "{\"version\":1,\"exchanges\":[],\"note\":\"é🦆\"}"
  let bytes = string.byte_size(raw)
  cassette.parse(raw, bytes) |> should.be_ok
  cassette.parse(raw, bytes - 1)
  |> should.equal(Error(cassette.TooLarge(bytes - 1, bytes)))
  let assert Ok(recording) = cassette.new([])
  let assert Ok(saved) = cassette.to_json(recording, 100_000)
  let bytes = string.byte_size(saved)
  cassette.to_json(recording, bytes) |> should.equal(Ok(saved))
  cassette.to_json(recording, bytes - 1)
  |> should.equal(Error(cassette.TooLarge(bytes - 1, bytes)))
  cassette.load("test/fixtures/cassette/hello.json", 9)
  |> should.equal(Error(cassette.TooLarge(9, 10)))
  cassette.load("test/fixtures/cassette/missing.json", 100_000)
  |> should.equal(Error(cassette.ReadError("enoent")))
  list.each([0, -1], fn(limit) {
    cassette.parse(raw, limit)
    |> should.equal(Error(cassette.InvalidLimit(limit)))
    cassette.to_json(recording, limit)
    |> should.equal(Error(cassette.InvalidLimit(limit)))
    cassette.load("test/fixtures/cassette/missing.json", limit)
    |> should.equal(Error(cassette.InvalidLimit(limit)))
  })
}

pub fn nesting_is_bounded_before_json_decode_but_quoted_brackets_are_data_test() {
  let nested = fn(depth) {
    "{\"version\":1,\"exchanges\":[],\"padding\":"
    <> string.repeat("[", depth)
    <> "0"
    <> string.repeat("]", depth)
    <> "}"
  }
  cassette.parse(nested(63), 100_000) |> should.be_ok
  cassette.parse(nested(64), 100_000) |> should.equal(Error(cassette.TooDeep))
  let quoted =
    json.object([
      #("version", json.int(1)),
      #("exchanges", json.array([], fn(x) { x })),
      #("padding", json.string(string.repeat("[\\\"🦆", 100))),
    ])
    |> json.to_string
  cassette.parse(quoted, 100_000) |> should.be_ok
}

pub fn cassette_construction_rejects_unsupported_transport_values_test() {
  let expected =
    testing.ExpectedRequest(
      "POST",
      "https://example.com/v1",
      "/v1/responses",
      "{}",
    )
  list.each(
    [
      testing.ExpectedRequest(..expected, method: "GET"),
      testing.ExpectedRequest(..expected, endpoint: "not a URL"),
      testing.ExpectedRequest(
        ..expected,
        endpoint: "https://user:secret@example.com",
      ),
      testing.ExpectedRequest(..expected, path: "relative"),
    ],
    fn(invalid) {
      let assert Error(cassette.InvalidExchange(1, _)) =
        cassette.new([
          testing.Exchange(invalid, testing.Events([])),
        ])
    },
  )
  list.each([99, 200, 600], fn(code) {
    let assert Error(cassette.InvalidExchange(1, _)) =
      cassette.new([
        testing.Exchange(expected, testing.Status(code, "no")),
      ])
  })
}

pub fn recorded_status_and_interruption_keep_normal_error_evidence_test() {
  let assert Ok(prepared) = session.prepare(settings(), request())
  let expected =
    testing.ExpectedRequest(
      "POST",
      "https://api.openai.com/v1",
      "/v1/responses",
      session.prepared_request_json(prepared),
    )
  let assert Ok(recording) =
    cassette.new([
      testing.Exchange(expected, testing.Status(429, "slow down")),
      testing.Exchange(expected, testing.Interrupted([])),
    ])
  let assert Ok(saved) = cassette.to_json(recording, 100_000)
  let assert Ok(recording) = cassette.parse(saved, 100_000)
  let script = cassette.start(recording)
  let assert Ok(prepared) =
    session.prepare(testing.with_script(settings(), script), request())
  let assert Error(session.RunFailure(
    types.HttpStatusError(429, "slow down", None),
    status_retry,
  )) = session.run(prepared)
  status_retry.classification
  |> should.equal(types.RequestMayHaveReachedProvider)
  let assert Error(session.RunFailure(types.TransportError(_), retry)) =
    session.run(prepared)
  retry.classification |> should.equal(types.RequestMayHaveReachedProvider)
  testing.remaining(script) |> should.equal(0)
}

fn encoded_exchange(
  request_fields: List(#(String, json.Json)),
  reply: json.Json,
) -> String {
  json.object([
    #("version", json.int(1)),
    #(
      "exchanges",
      json.array(
        [
          json.object([
            #("request", json.object(request_fields)),
            #("reply", reply),
          ]),
        ],
        fn(value) { value },
      ),
    ),
  ])
  |> json.to_string
}

pub fn every_request_field_and_reply_tag_is_required_and_typed_test() {
  let fields = [
    #("method", json.string("POST")),
    #("endpoint", json.string("https://example.com/v1")),
    #("path", json.string("/v1/responses")),
    #("body", json.string("{}")),
  ]
  let reply =
    json.object([
      #("kind", json.string("events")),
      #("chunks", json.array([], fn(x) { x })),
    ])
  list.each(fields, fn(field) {
    let missing = list.filter(fields, fn(candidate) { candidate.0 != field.0 })
    encoded_exchange(missing, reply)
    |> cassette.parse(100_000)
    |> should.equal(Error(cassette.InvalidJson))
    let wrong_type =
      list.map(fields, fn(candidate) {
        case candidate.0 == field.0 {
          True -> #(candidate.0, json.int(1))
          False -> candidate
        }
      })
    encoded_exchange(wrong_type, reply)
    |> cassette.parse(100_000)
    |> should.equal(Error(cassette.InvalidJson))
  })
  list.each(
    [
      json.object([]),
      json.object([#("kind", json.string("unknown"))]),
      json.object([#("kind", json.string("events"))]),
      json.object([
        #("kind", json.string("events")),
        #("chunks", json.string("not a list")),
      ]),
      json.object([
        #("kind", json.string("events")),
        #("chunks", json.array([1], json.int)),
      ]),
      json.object([#("kind", json.string("interrupted"))]),
      json.object([#("kind", json.string("status")), #("code", json.int(429))]),
      json.object([
        #("kind", json.string("status")),
        #("body", json.string("missing code")),
      ]),
      json.object([
        #("kind", json.string("status")),
        #("code", json.string("429")),
        #("body", json.string("wrong code type")),
      ]),
    ],
    fn(invalid_reply) {
      encoded_exchange(fields, invalid_reply)
      |> cassette.parse(100_000)
      |> should.equal(Error(cassette.InvalidJson))
    },
  )
  let invalid_method = [#("method", json.string("GET")), ..list.drop(fields, 1)]
  let assert Error(cassette.InvalidExchange(1, _)) =
    cassette.parse(encoded_exchange(invalid_method, reply), 100_000)
}

pub fn disk_limit_is_exact_and_invalid_utf8_is_a_typed_failure_test() {
  let path = "test/fixtures/cassette/hello.json"
  let assert Ok(bytes) = read_file(path)
  let size = bit_array.byte_size(bytes)
  cassette.load(path, size) |> should.be_ok
  cassette.load(path, size - 1)
  |> should.equal(Error(cassette.TooLarge(size - 1, size)))
  cassette.load("test/fixtures/cassette/invalid_utf8.bin", 100)
  |> should.equal(Error(cassette.InvalidUtf8))
}

pub fn a_corrected_request_can_consume_after_mismatch_test() {
  let assert Ok(recording) =
    cassette.load("test/fixtures/cassette/hello.json", 10_000)
  let script = cassette.start(recording)
  let settings = testing.with_script(settings(), script)
  let wrong =
    types.Request(..request(), messages: [types.UserMessage("Different")])
  let assert Ok(prepared) = session.prepare(settings, wrong)
  let assert Error(session.RunFailure(types.ConfigurationError(_), _)) =
    session.run(prepared)
  let assert Ok(prepared) = session.prepare(settings, request())
  session.run(prepared)
  |> should.equal(Ok(session.RunText("first fixture", None)))
  testing.remaining(script) |> should.equal(0)
  list.length(testing.requests(script)) |> should.equal(2)
}

pub fn replayed_partial_stream_preserves_interruption_evidence_test() {
  let assert Ok(prepared) = session.prepare(settings(), request())
  let expected =
    testing.ExpectedRequest(
      "POST",
      "https://api.openai.com/v1",
      "/v1/responses",
      session.prepared_request_json(prepared),
    )
  let assert testing.Events(chunks) = response("observed")
  let partial = list.take(chunks, 2) |> string.join("")
  let split_chunks = [
    string.slice(partial, 0, 23),
    string.drop_start(partial, 23),
  ]
  let assert Ok(recording) =
    cassette.new([
      testing.Exchange(expected, testing.Interrupted(split_chunks)),
    ])
  let assert Ok(saved) = cassette.to_json(recording, 100_000)
  let assert Ok(recording) = cassette.parse(saved, 100_000)
  let script = cassette.start(recording)
  let assert Ok(prepared) =
    session.prepare(testing.with_script(settings(), script), request())
  let assert Error(session.RunFailure(types.TransportError(_), retry)) =
    session.run(prepared)
  retry.response_bytes_observed |> should.be_true
  retry.semantic_progress_observed |> should.be_true
  retry.classification |> should.equal(types.RequestMayHaveReachedProvider)
}

@external(erlang, "file", "read_file")
fn read_file(path: String) -> Result(BitArray, atom.Atom)

pub fn unexpected_success_statuses_match_the_http_transport_test() {
  let assert Ok(prepared) = session.prepare(settings(), request())
  let expected =
    testing.ExpectedRequest(
      "POST",
      "https://api.openai.com/v1",
      "/v1/responses",
      session.prepared_request_json(prepared),
    )
  list.each([201, 204, 299], fn(code) {
    let assert Ok(recording) =
      cassette.new([
        testing.Exchange(expected, testing.Status(code, "unexpected")),
      ])
    let assert Ok(raw) = cassette.to_json(recording, 10_000)
    let assert Ok(recording) = cassette.parse(raw, 10_000)
    let script = cassette.start(recording)
    let assert Ok(prepared) =
      session.prepare(testing.with_script(settings(), script), request())
    let assert Error(session.RunFailure(
      types.HttpStatusError(actual, "unexpected", None),
      _,
    )) = session.run(prepared)
    actual |> should.equal(code)
  })
}
