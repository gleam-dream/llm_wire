//// Stop reasons through the public facade. A stop reason a built-in reducer
//// knows maps to the outcome it means; one it does not know ends the call
//// with `UnrecognizedStop`, keeping what the provider sent, so the caller
//// decides what it means instead of losing a paid answer to a failure.

import gleam/list
import gleam/option.{None, Some}
import http_test_helpers
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/google
import llm_wire/message
import llm_wire/openai
import llm_wire/testing

fn run_in(
  config: llm_wire.Config,
  events: List(String),
) -> Result(llm_wire.Outcome(String), llm_wire.Failure) {
  let assert Ok(prepared) =
    llm_wire.prepare(config, llm_wire.request("fixture", [message.User("hi")]))
  http_test_helpers.run_reply(prepared, testing.events(events))
}

// --- Anthropic ---------------------------------------------------------------

const anthropic_start =
  "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude\",\"usage\":{\"input_tokens\":4,\"output_tokens\":1}}}\n\n"
  <> "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n"
  <> "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"so far\"}}\n\n"
  <> "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n"

fn anthropic_stop(reason: String) -> String {
  "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\""
  <> reason
  <> "\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":3}}\n\n"
  <> "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"
}

fn anthropic_config() -> llm_wire.Config {
  anthropic.new("k") |> anthropic.config
}

pub fn anthropic_unknown_stop_reason_keeps_the_text_test() {
  let assert Ok(llm_wire.UnrecognizedStop(
    reason: "a_future_reason",
    partial_text: "so far",
    partial_calls: [],
    usage: Some(message.Usage(input_tokens: 4, output_tokens: 3, ..)),
  )) =
    run_in(anthropic_config(), [
      anthropic_start,
      anthropic_stop("a_future_reason"),
    ])
}

/// Anthropic returns `model_context_window_exceeded` when the answer filled
/// the context window: the output was cut, as with `max_tokens`.
pub fn anthropic_context_window_exceeded_is_output_limited_test() {
  let assert Ok(llm_wire.OutputLimited(partial_text: "so far", ..)) =
    run_in(anthropic_config(), [
      anthropic_start,
      anthropic_stop("model_context_window_exceeded"),
    ])
}

// --- OpenAI ------------------------------------------------------------------

fn openai_incomplete(reason: String) -> List(String) {
  [
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"message\"}}\n\n",
    "event: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"i\",\"delta\":\"so far\"}\n\n",
    "event: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"i\",\"type\":\"message\"}}\n\n",
    "event: response.incomplete\ndata: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"r\",\"status\":\"incomplete\",\"error\":null,\"incomplete_details\":{\"reason\":\""
      <> reason
      <> "\"}}}\n\n",
  ]
}

pub fn openai_unknown_incomplete_reason_keeps_the_text_test() {
  let config = openai.new("k") |> openai.config
  let assert Ok(llm_wire.UnrecognizedStop(
    reason: "a_future_reason",
    partial_text: "so far",
    partial_calls: [],
    usage: None,
  )) = run_in(config, openai_incomplete("a_future_reason"))
}

// --- Google ------------------------------------------------------------------

fn google_finish(reason: String) -> List(String) {
  [
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"so far\"}]}}]}\n\n",
    "data: {\"candidates\":[{\"finishReason\":\""
      <> reason
      <> "\",\"content\":{\"role\":\"model\",\"parts\":[]}}]}\n\n",
  ]
}

fn google_config() -> llm_wire.Config {
  google.new("k") |> google.config
}

/// `OTHER` is Gemini's own "unknown reason", and a value missing from the
/// enum is new to this version: neither says whether the text is complete.
pub fn google_unknown_finish_reason_keeps_the_text_test() {
  use reason <- list.each(["A_FUTURE_REASON", "OTHER"])
  let assert Ok(llm_wire.UnrecognizedStop(
    reason: found,
    partial_text: "so far",
    partial_calls: [],
    usage: None,
  )) = run_in(google_config(), google_finish(reason))
  assert found == reason
}

/// `CONTINUATION` means the per-request token budget ran out before the
/// answer finished: the output was cut.
pub fn google_continuation_is_output_limited_test() {
  let assert Ok(llm_wire.OutputLimited(partial_text: "so far", ..)) =
    run_in(google_config(), google_finish("CONTINUATION"))
}

/// Filter reasons added to the enum fail as content filtering, like the
/// filters already known.
pub fn google_newer_filter_reasons_are_content_filtered_test() {
  use reason <- list.each(["ESCALATION", "IMAGE_RECITATION"])
  let assert Error(failure) = run_in(google_config(), google_finish(reason))
  assert failure.error == error.ContentFiltered(error.InOutput, reason)
}

/// A known reason that names a provider-side fault stays a failure: the
/// reason is modelled, and it does not describe an answer.
pub fn google_known_fault_reasons_still_fail_test() {
  use reason <- list.each([
    "MALFORMED_FUNCTION_CALL", "UNEXPECTED_TOOL_CALL", "TOO_MANY_TOOL_CALLS",
    "MISSING_THOUGHT_SIGNATURE", "MALFORMED_RESPONSE",
  ])
  let assert Error(failure) = run_in(google_config(), google_finish(reason))
  let assert error.Provider(code: Some(code), ..) = failure.error
  assert code == reason
}

// --- the scripted wire ---------------------------------------------------------

/// `testing.unrecognized_stop` lowers into every wire with the reason as the
/// wire's own value, so an application can test its `UnrecognizedStop` arm.
pub fn the_testing_kit_scripts_an_unrecognized_stop_in_every_wire_test() {
  use config <- list.each([
    testing.config(),
    openai.new("k") |> openai.config,
    anthropic_config(),
    google_config(),
  ])
  let assert Ok(prepared) =
    llm_wire.prepare(config, llm_wire.request("fixture", [message.User("hi")]))
  let assert Ok(llm_wire.UnrecognizedStop(
    reason: "vendor_reason",
    partial_text: "so far",
    ..,
  )) =
    http_test_helpers.run_reply(
      prepared,
      testing.unrecognized_stop("vendor_reason", "so far"),
    )
}
