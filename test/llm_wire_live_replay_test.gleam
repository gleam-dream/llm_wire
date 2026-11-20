//// Replays the cassettes recorded from the live Gemini and OpenAI APIs
//// (`dev/record-live`) on 2026-10-04, all but `openai-union-written`
//// recorded again on 2026-11-18 so that each ends `finished`, offline and
//// without keys. Each reply
//// decodes through the original codec and is classified as the live call
//// was: a nested union of strict objects sent as Gemini's
//// `responseJsonSchema` and OpenAI's strict `json_schema`, Gemini's plain
//// text stream and a Gemini tool call with its signed part. Round 7 added
//// Gemini's nested `codec.nullable` (a null and a non-null reply) and one
//// schema with an optional field, a number range, a pair and
//// `codec.value()`, all of which the strict profile refuses. On 2026-11-19
//// five scenarios on `gpt-6.2-sol` with responses unstored added a PDF
//// file part, an optional field answered null and answered, and a tool
//// round of two exchanges (ADR 0021).

import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import http_gun
import http_gun/cassette
import http_gun/testing as http_testing
import json/blueprint/codec
import json/blueprint/number
import json/blueprint/value
import live_scenarios.{
  type Scenario, Address, Contact, NoSources, Reading, Written,
}
import llm_wire
import llm_wire/message
import llm_wire/tool
import simplifile

/// Credentials are neither stored nor compared, so any key replays.
const key = "replay-placeholder-key"

fn with_tape(scenario: Scenario, run: fn(http_gun.Client) -> a) -> a {
  let assert Ok(tape) = cassette.load(live_scenarios.path(scenario), 1_000_000)
  let assert Ok(client) = http_testing.playback(tape, live_scenarios.http())
  let result = run(client)
  http_gun.stop(client)
  result
}

/// Reads a stream to its end: the text deltas in order and the outcome.
fn drain(
  stream: llm_wire.Stream(o),
  deltas: List(String),
) -> #(List(String), Result(llm_wire.Outcome(o), llm_wire.Failure)) {
  let assert Ok(event) = llm_wire.next(stream)
  case event {
    llm_wire.Progress(message.TextDelta(_, text)) ->
      drain(stream, [text, ..deltas])
    llm_wire.Progress(_) -> drain(stream, deltas)
    llm_wire.Done(outcome) -> #(list.reverse(deltas), outcome)
  }
}

fn structured(scenario: Scenario) -> llm_wire.Prepared(live_scenarios.Answer) {
  live_scenarios.structured_call(scenario, key)
}

/// Runs a structured scenario, then checks that the answer text decodes
/// through the original codec, on its own, to the same value.
fn answer(scenario: Scenario) -> live_scenarios.Answer {
  use client <- with_tape(scenario)
  let assert Ok(llm_wire.Answer(output:, text:, usage: Some(_))) =
    llm_wire.run(client, structured(scenario))
  codec.decode_json(live_scenarios.output(), text) |> should.equal(Ok(output))
  output
}

pub fn gemini_accepts_the_union_as_response_json_schema_test() {
  let body = llm_wire.request_json(structured(live_scenarios.GoogleWritten))
  string.contains(body, "\"responseJsonSchema\":{") |> should.be_true
  string.contains(body, "\"responseSchema\"") |> should.be_false
  string.contains(body, "\"anyOf\":[") |> should.be_true
  string.contains(body, "\"additionalProperties\":false") |> should.be_true
}

pub fn gemini_written_variant_decodes_through_the_codec_test() {
  let assert Written(title: "Tides", body:) =
    answer(live_scenarios.GoogleWritten)
  string.contains(body, "tide") |> should.be_true
}

pub fn gemini_payload_variant_decodes_through_the_codec_test() {
  let assert NoSources(reason:) = answer(live_scenarios.GoogleNoSources)
  string.is_empty(reason) |> should.be_false
}

pub fn openai_written_variant_decodes_through_the_codec_test() {
  let assert Written(title: "Tides", body:) =
    answer(live_scenarios.OpenAiWritten)
  string.contains(body, "tide") |> should.be_true
}

pub fn openai_payload_variant_decodes_through_the_codec_test() {
  let assert NoSources(reason:) = answer(live_scenarios.OpenAiNoSources)
  string.is_empty(reason) |> should.be_false
}

pub fn streamed_structured_deltas_rebuild_the_decoded_answer_test() {
  use scenario <- list.each([
    live_scenarios.GoogleWritten,
    live_scenarios.OpenAiNoSources,
  ])
  use client <- with_tape(scenario)
  let assert Ok(stream) = llm_wire.stream(client, structured(scenario))
  let assert #(deltas, Ok(llm_wire.Answer(output:, text:, ..))) =
    drain(stream, [])
  string.concat(deltas) |> should.equal(text)
  codec.decode_json(live_scenarios.output(), text) |> should.equal(Ok(output))
}

pub fn gemini_text_streams_in_several_deltas_test() {
  use client <- with_tape(live_scenarios.GoogleText)
  let assert Ok(stream) = llm_wire.stream(client, live_scenarios.text_call(key))
  let assert #(deltas, Ok(llm_wire.Answer(output:, text:, usage: Some(_)))) =
    drain(stream, [])
  output |> should.equal(text)
  string.concat(deltas) |> should.equal(text)
  { list.length(deltas) > 1 } |> should.be_true
  string.starts_with(string.lowercase(text), "one") |> should.be_true
  string.ends_with(string.lowercase(string.trim(text)), "twenty")
  |> should.be_true
}

pub fn gemini_tool_call_needs_tools_and_replays_its_signed_part_test() {
  use client <- with_tape(live_scenarios.GoogleTool)
  let assert Ok(llm_wire.NeedsTools(turn:, issues: [], usage: Some(_))) =
    llm_wire.run(client, live_scenarios.tool_call(key))
  turn.provider |> should.equal(Some(message.Google))
  let assert [call] = turn.calls
  call.name |> should.equal("get_weather")
  tool.decode_arguments(call, live_scenarios.city())
  |> should.equal(Ok("Paris"))
  // Gemini signs the call; the follow-up must carry the signature back.
  let assert Some(_) = turn.provider_data
  let follow_up =
    llm_wire.append(live_scenarios.tool_request(), [
      message.Assistant(turn),
      llm_wire.tool_result(
        call,
        json.to_string(json.object([#("forecast", json.string("sunny"))])),
      ),
    ])
  let assert Ok(prepared) = llm_wire.prepare(google_config(), follow_up)
  string.contains(llm_wire.request_json(prepared), "\"thoughtSignature\"")
  |> should.be_true
}

fn google_config() -> llm_wire.Config {
  live_scenarios.google_config(key)
}

/// Runs a Gemini scenario whose output is not the union, and checks that
/// the answer text decodes through the codec, on its own, to the same value.
fn gemini_answer(
  scenario: Scenario,
  prepared: llm_wire.Prepared(o),
  output: codec.Codec(o),
) -> #(o, String) {
  use client <- with_tape(scenario)
  let assert Ok(llm_wire.Answer(output: decoded, text:, usage: Some(_))) =
    llm_wire.run(client, prepared)
  codec.decode_json(output, text) |> should.equal(Ok(decoded))
  #(decoded, text)
}

pub fn gemini_sends_nullable_as_any_of_with_null_test() {
  let body =
    llm_wire.request_json(live_scenarios.nullable_call(
      live_scenarios.GoogleNullableNull,
      key,
    ))
  string.contains(
    body,
    "\"phone\":{\"anyOf\":[{\"type\":\"null\"},{\"type\":\"string\"}]}",
  )
  |> should.be_true
  string.contains(body, "\"address\":{\"anyOf\":[{\"type\":\"null\"},")
  |> should.be_true
}

pub fn gemini_nested_nullable_replies_null_test() {
  let scenario = live_scenarios.GoogleNullableNull
  let #(contact, text) =
    gemini_answer(
      scenario,
      live_scenarios.nullable_call(scenario, key),
      live_scenarios.contact_output(),
    )
  contact |> should.equal(Contact("Ada Lovelace", None, None))
  string.contains(text, "\"phone\":null") |> should.be_true
}

pub fn gemini_nested_nullable_replies_a_value_test() {
  let scenario = live_scenarios.GoogleNullableValue
  let #(contact, _) =
    gemini_answer(
      scenario,
      live_scenarios.nullable_call(scenario, key),
      live_scenarios.contact_output(),
    )
  contact
  |> should.equal(Contact("Bob Stone", Some("555-0100"), Some(Address("Paris"))))
}

pub fn gemini_takes_an_optional_field_range_pair_and_any_value_test() {
  let prepared = live_scenarios.wide_call(key)
  let body = llm_wire.request_json(prepared)
  string.contains(
    body,
    "\"required\":[\"label\",\"score\",\"point\",\"extra\"]",
  )
  |> should.be_true
  string.contains(body, "\"minimum\":0,\"maximum\":1") |> should.be_true
  string.contains(body, "\"prefixItems\":[") |> should.be_true
  string.contains(body, "\"extra\":{}") |> should.be_true
  let #(reading, text) =
    gemini_answer(
      live_scenarios.GoogleWideSchema,
      prepared,
      live_scenarios.reading_output(),
    )
  let assert Reading(label: "north", note: None, score:, point: #(3, 4), extra:) =
    reading
  // The model left the optional field out rather than sending null.
  string.contains(text, "\"note\"") |> should.be_false
  number.to_float(score) |> should.equal(Ok(0.75))
  extra
  |> should.equal(value.Object([#("unit", value.String("cm"))]))
}

/// A live recording stores what the provider sent, to the end of the body.
/// A cut-off ending would mean the client closed the body early (ADR 0019).
pub fn every_live_cassette_ends_finished_test() {
  let paths = [
    "test/cassettes/live/typesafe-classification.json",
    ..list.map(live_scenarios.all(), live_scenarios.path)
  ]
  list.each(paths, fn(path) {
    let assert Ok(tape) = cassette.load(path, 1_000_000)
    let endings =
      list.map(http_testing.exchanges(tape), fn(exchange) {
        case http_testing.reply(exchange) {
          http_testing.Respond(ending: http_testing.Finished(_), ..) ->
            "finished"
          http_testing.Respond(ending: http_testing.Abandoned, ..) ->
            "abandoned"
          http_testing.Respond(ending: http_testing.Aborted(_), ..) -> "aborted"
          http_testing.Reject(_) -> "rejected"
        }
      })
    let expected = case
      path == live_scenarios.path(live_scenarios.OpenAiToolRound)
    {
      True -> ["finished", "finished"]
      False -> ["finished"]
    }
    #(path, endings) |> should.equal(#(path, expected))
  })
}

fn thinking_run(scenario: Scenario) {
  let call = live_scenarios.thinking_call(scenario, key)
  use client <- with_tape(scenario)
  #(llm_wire.request_json(call), llm_wire.run(client, call))
}

pub fn gemini_takes_a_thinking_level_test() {
  let #(body, outcome) = thinking_run(live_scenarios.GoogleThinkingLevel)
  string.contains(body, "\"thinkingConfig\":{\"thinkingLevel\":\"LOW\"}")
  |> should.be_true
  // At Low the model reported no thinking: no thought count, and output is
  // the visible token alone.
  let assert Ok(llm_wire.Answer(
    output: "Paris",
    usage: Some(message.Usage(
      input_tokens: 13,
      output_tokens: 1,
      total_tokens: 14,
      thought_tokens: None,
    )),
    ..,
  )) = outcome
}

/// dash-crm's case at a small limit: Gemini spent the whole limit thinking,
/// left out its candidate count, and the result still says how.
pub fn gemini_cut_off_while_thinking_shows_how_the_limit_was_spent_test() {
  let #(_, outcome) = thinking_run(live_scenarios.GoogleThoughtLimit)
  outcome
  |> should.equal(
    Ok(llm_wire.OutputLimited(
      partial_text: "",
      partial_calls: [],
      usage: Some(message.Usage(
        input_tokens: 20,
        output_tokens: 60,
        total_tokens: 80,
        thought_tokens: Some(60),
      )),
    )),
  )
}

pub fn openai_takes_a_reasoning_effort_test() {
  let #(body, outcome) = thinking_run(live_scenarios.OpenAiThinkingLevel)
  string.contains(body, "\"reasoning\":{\"effort\":\"low\"}") |> should.be_true
  let assert Ok(llm_wire.Answer(
    output: "Paris",
    usage: Some(message.Usage(thought_tokens: Some(_), ..)),
    ..,
  )) = outcome
}

// --- OpenAI Responses on gpt-6.2-sol (ADR 0021) -------------------------------
// Recorded on 2026-11-19 with responses unstored.

fn sol_body(prepared: llm_wire.Prepared(o)) -> String {
  let body = llm_wire.request_json(prepared)
  string.contains(body, "\"model\":\"gpt-6.2-sol\"") |> should.be_true
  string.contains(body, "\"store\":false") |> should.be_true
  string.contains(body, "\"temperature\"") |> should.be_false
  string.contains(body, "\"top_p\"") |> should.be_false
  body
}

pub fn sol_pdf_is_sent_as_an_input_file_test() {
  let body = sol_body(live_scenarios.pdf_call(key))
  string.contains(
    body,
    "{\"type\":\"input_file\",\"filename\":\"invoice.pdf\",\"file_data\":\"data:application/pdf;base64,JVBERi0xLjQK",
  )
  |> should.be_true
}

pub fn sol_optional_field_is_sent_required_and_nullable_test() {
  use scenario <- list.each([
    live_scenarios.OpenAiOptionalNull,
    live_scenarios.OpenAiOptionalValue,
  ])
  let body = sol_body(live_scenarios.optional_call(scenario, key))
  string.contains(
    body,
    "\"nickname\":{\"anyOf\":[{\"type\":\"null\"},{\"type\":\"string\"}]}},\"required\":[\"name\",\"nickname\"]",
  )
  |> should.be_true
}

pub fn sol_store_false_is_sent_test() {
  let _ = sol_body(live_scenarios.store_call(key))
  Nil
}

pub fn sol_tool_round_asks_medium_reasoning_and_a_non_strict_tool_test() {
  let assert Ok(prepared) =
    llm_wire.prepare(
      live_scenarios.sol_config(key),
      live_scenarios.tool_round_request(),
    )
  let body = sol_body(prepared)
  string.contains(body, "\"reasoning\":{\"effort\":\"medium\"}")
  |> should.be_true
  string.contains(body, "\"strict\":false") |> should.be_true
  string.contains(body, "\"include\"") |> should.be_false
}

fn sol_answer(
  scenario: Scenario,
  prepared: llm_wire.Prepared(o),
  output: codec.Codec(o),
) -> #(o, String) {
  use client <- with_tape(scenario)
  let assert Ok(llm_wire.Answer(output: decoded, text:, usage: Some(_))) =
    llm_wire.run(client, prepared)
  codec.decode_json(output, text) |> should.equal(Ok(decoded))
  #(decoded, text)
}

pub fn sol_reads_the_pdf_into_the_codec_test() {
  let #(invoice, _) =
    sol_answer(
      live_scenarios.OpenAiFilePdf,
      live_scenarios.pdf_call(key),
      live_scenarios.invoice_output(),
    )
  invoice |> should.equal(live_scenarios.Invoice("A-17", "42.50", "EUR"))
}

/// The model wrote `"nickname":null`; the answer reads it as absent, and
/// `Answer.text` no longer holds the member.
pub fn sol_null_for_an_optional_field_reads_as_absent_test() {
  let scenario = live_scenarios.OpenAiOptionalNull
  let assert Ok(raw) = simplifile.read(live_scenarios.path(scenario))
  // The answer text sits two JSON strings deep in the cassette.
  string.contains(raw, "\\\\\\\"nickname\\\\\\\":null") |> should.be_true
  let #(person, text) =
    sol_answer(
      scenario,
      live_scenarios.optional_call(scenario, key),
      live_scenarios.person_output(),
    )
  person |> should.equal(live_scenarios.Person("Ada Lovelace", None))
  text |> should.equal("{\"person\":{\"name\":\"Ada Lovelace\"}}")
}

pub fn sol_optional_field_with_a_value_test() {
  let scenario = live_scenarios.OpenAiOptionalValue
  let #(person, _) =
    sol_answer(
      scenario,
      live_scenarios.optional_call(scenario, key),
      live_scenarios.person_output(),
    )
  person |> should.equal(live_scenarios.Person("Robert Stone", Some("Bobby")))
}

pub fn sol_answers_with_store_false_test() {
  use client <- with_tape(live_scenarios.OpenAiStoreFalse)
  let assert Ok(llm_wire.Answer(output: "Paris", ..)) =
    llm_wire.run(client, live_scenarios.store_call(key))
}

/// The call streams `function_call_arguments.done` before
/// `output_item.done`, and the follow-up replays it with `call_id` only and
/// no reasoning item; OpenAI accepts it. The model reported no reasoning
/// tokens at medium effort, so this round had no reasoning item to leave
/// out.
pub fn sol_tool_round_is_accepted_without_reasoning_items_test() {
  let assert Ok(raw) =
    simplifile.read(live_scenarios.path(live_scenarios.OpenAiToolRound))
  string.contains(raw, "response.function_call_arguments.done")
  |> should.be_true
  // Output item types sit one JSON string deep in the cassette.
  string.contains(raw, "\\\"type\\\":\\\"function_call\\\"")
  |> should.be_true
  string.contains(raw, "\\\"type\\\":\\\"reasoning\\\"")
  |> should.be_false
  use client <- with_tape(live_scenarios.OpenAiToolRound)
  let assert Ok(#(
    llm_wire.NeedsTools(turn:, issues: [], ..),
    Some(llm_wire.Answer(output:, ..)),
  )) = live_scenarios.tool_round(client, key)
  let assert [call] = turn.calls
  call.name |> should.equal("get_weather")
  tool.decode_arguments(call, live_scenarios.city())
  |> should.equal(Ok("Paris"))
  string.contains(output, "Paris") |> should.be_true
  string.contains(output, "sunny") |> should.be_true
}
