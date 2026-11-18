//// Usage counts thoughts inside output tokens and reports them apart, on
//// every built-in provider that reports a thought count (ADR 0020).

import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import http_test_helpers
import llm_wire
import llm_wire/anthropic as anthropic_options
import llm_wire/google as google_options
import llm_wire/internal/anthropic
import llm_wire/internal/google
import llm_wire/internal/limits
import llm_wire/internal/openai
import llm_wire/internal/sse
import llm_wire/internal/stream_types
import llm_wire/message
import llm_wire/openai as openai_options
import llm_wire/testing

fn data(text: String) -> sse.ServerSentEvent {
  sse.ServerSentEvent(event: None, data: text, id: None, retry: None)
}

fn named(name: String, text: String) -> sse.ServerSentEvent {
  sse.ServerSentEvent(event: Some(name), data: text, id: None, retry: None)
}

fn usage(input: Int, output: Int, total: Int, thought) -> message.Usage {
  message.Usage(
    input_tokens: input,
    output_tokens: output,
    total_tokens: total,
    thought_tokens: thought,
  )
}

// --- Google --------------------------------------------------------------

/// dash-crm's case: the limit ended the response after 979 thought and 41
/// visible tokens.
pub fn google_output_counts_thoughts_and_reports_them_apart_test() {
  let reducer = google.new(limits.default())
  let assert Ok(#(reducer, progress)) =
    google.step(
      reducer,
      data(
        "{\"candidates\":[{\"finishReason\":\"MAX_TOKENS\",\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Par\"}]}}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":41,\"thoughtsTokenCount\":979,\"totalTokenCount\":1030}}",
      ),
    )
  let expected = usage(10, 1020, 1030, Some(979))
  list.contains(progress, message.UsageUpdate(expected)) |> should.be_true
  let assert Some(stream_types.StreamFinished(
    outcome: stream_types.OutputLimited(_, _),
    usage: Some(reported),
  )) = google.terminal(reducer)
  reported |> should.equal(expected)
}

/// Google leaves out a count that is zero: a response that only thought has
/// no candidate count, and its usage is still reported.
pub fn google_reads_an_absent_candidate_count_as_zero_test() {
  let reducer = google.new(limits.default())
  let assert Ok(#(reducer, _)) =
    google.step(
      reducer,
      data(
        "{\"candidates\":[{\"finishReason\":\"MAX_TOKENS\",\"content\":{\"role\":\"model\"}}],\"usageMetadata\":{\"promptTokenCount\":10,\"thoughtsTokenCount\":1024,\"totalTokenCount\":1034}}",
      ),
    )
  let assert Some(stream_types.StreamFinished(
    outcome: stream_types.OutputLimited("", []),
    usage: Some(reported),
  )) = google.terminal(reducer)
  reported |> should.equal(usage(10, 1024, 1034, Some(1024)))
}

pub fn google_without_a_thought_count_reports_none_test() {
  let reducer = google.new(limits.default())
  let assert Ok(#(_, progress)) =
    google.step(
      reducer,
      data(
        "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"Hi\"}]}}],\"usageMetadata\":{\"promptTokenCount\":5,\"candidatesTokenCount\":3,\"totalTokenCount\":8}}",
      ),
    )
  list.contains(progress, message.UsageUpdate(usage(5, 3, 8, None)))
  |> should.be_true
}

// --- OpenAI --------------------------------------------------------------

pub fn openai_reports_reasoning_tokens_as_thought_test() {
  let reducer = openai.new(limits.default())
  let assert Ok(#(_, progress)) =
    openai.step(
      reducer,
      named(
        "response.completed",
        "{\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":1186,\"total_tokens\":1191,\"output_tokens_details\":{\"reasoning_tokens\":1024}}}}",
      ),
    )
  progress
  |> should.equal([message.UsageUpdate(usage(5, 1186, 1191, Some(1024)))])
}

// --- Anthropic -----------------------------------------------------------

fn anthropic_start(reducer) {
  let assert Ok(#(reducer, _)) =
    anthropic.step(
      reducer,
      named(
        "message_start",
        "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"usage\":{\"input_tokens\":15,\"output_tokens\":1}}}",
      ),
    )
  reducer
}

fn anthropic_events(reducer, events: List(sse.ServerSentEvent)) {
  list.fold(events, #(reducer, []), fn(acc, event) {
    let #(reducer, seen) = acc
    let assert Ok(#(reducer, progress)) = anthropic.step(reducer, event)
    #(reducer, list.append(seen, progress))
  })
}

pub fn anthropic_reports_thinking_tokens_as_thought_test() {
  let reducer = anthropic_start(anthropic.new(limits.default()))
  let #(_, progress) =
    anthropic_events(reducer, [
      named(
        "message_delta",
        "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":50,\"output_tokens_details\":{\"thinking_tokens\":30}}}",
      ),
    ])
  progress
  |> should.equal([message.UsageUpdate(usage(15, 50, 65, Some(30)))])
}

pub fn anthropic_thinking_is_reasoning_and_not_answer_text_test() {
  let reducer = anthropic_start(anthropic.new(limits.default()))
  let #(reducer, progress) =
    anthropic_events(reducer, [
      named(
        "content_block_start",
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}",
      ),
      named(
        "content_block_delta",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"Let me think.\"}}",
      ),
      named(
        "content_block_delta",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"signature_delta\",\"signature\":\"sig==\"}}",
      ),
      named(
        "content_block_stop",
        "{\"type\":\"content_block_stop\",\"index\":0}",
      ),
      named(
        "content_block_start",
        "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"redacted_thinking\",\"data\":\"opaque\"}}",
      ),
      named(
        "content_block_stop",
        "{\"type\":\"content_block_stop\",\"index\":1}",
      ),
      named(
        "content_block_start",
        "{\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
      ),
      named(
        "content_block_delta",
        "{\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"text_delta\",\"text\":\"Paris.\"}}",
      ),
      named(
        "content_block_stop",
        "{\"type\":\"content_block_stop\",\"index\":2}",
      ),
      named(
        "message_delta",
        "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":40,\"output_tokens_details\":{\"thinking_tokens\":36}}}",
      ),
      named("message_stop", "{\"type\":\"message_stop\"}"),
    ])
  list.contains(progress, message.ReasoningDelta("0", "Let me think."))
  |> should.be_true
  list.contains(progress, message.TextDelta("2", "Paris.")) |> should.be_true
  anthropic.terminal(reducer)
  |> should.equal(
    Some(stream_types.StreamFinished(
      outcome: stream_types.CompletedText("Paris."),
      usage: Some(usage(15, 40, 55, Some(36))),
    )),
  )
}

// --- Semantic test replies -----------------------------------------------

/// A scripted reply's thought count survives lowering into each built-in
/// wire and reduction back, on the streamed and the whole-answer paths.
pub fn scripted_thought_usage_round_trips_each_provider_test() {
  let reported = usage(10, 1020, 1030, Some(979))
  list.each(
    [
      openai_options.new("key") |> openai_options.config,
      anthropic_options.new("key") |> anthropic_options.config,
      google_options.new("key") |> google_options.config,
    ],
    fn(config) {
      let assert Ok(prepared) =
        llm_wire.prepare(
          config,
          llm_wire.request("model-x", [message.User("Hi")]),
        )
      http_test_helpers.run_reply(
        prepared,
        testing.output_limited("Par") |> testing.with_usage(reported),
      )
      |> should.equal(Ok(llm_wire.OutputLimited("Par", [], Some(reported))))
    },
  )
}

/// A provider may send the details member as null; usage still decodes.
pub fn a_null_details_member_reads_as_no_thought_count_test() {
  let assert Ok(#(_, progress)) =
    openai.step(
      openai.new(limits.default()),
      named(
        "response.completed",
        "{\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"total_tokens\":8,\"output_tokens_details\":null}}}",
      ),
    )
  progress |> should.equal([message.UsageUpdate(usage(5, 3, 8, None))])
  let reducer = anthropic_start(anthropic.new(limits.default()))
  let #(_, progress) =
    anthropic_events(reducer, [
      named(
        "message_delta",
        "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":15,\"output_tokens_details\":null}}",
      ),
    ])
  progress |> should.equal([message.UsageUpdate(usage(15, 15, 30, None))])
}

/// Thinking belongs in a thinking block; on a text block it is a protocol
/// failure rather than answer text.
pub fn a_thinking_delta_on_a_text_block_fails_test() {
  let reducer = anthropic_start(anthropic.new(limits.default()))
  let assert Ok(#(reducer, _)) =
    anthropic.step(
      reducer,
      named(
        "content_block_start",
        "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}",
      ),
    )
  let assert Error(_) =
    anthropic.step(
      reducer,
      named(
        "content_block_delta",
        "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"secret\"}}",
      ),
    )
}
