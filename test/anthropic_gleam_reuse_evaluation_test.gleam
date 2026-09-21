import anthropic/http as anthropic_http
import anthropic/message as anthropic_message
import anthropic/request as anthropic_request
import anthropic/streaming/handler as anthropic_handler
import gleam/list
import gleam/string
import gleeunit/should

/// Evaluates only the published sans-I/O surface. The retained event list is
/// intentionally measured here to decide whether this handler can sit behind
/// the bounded owner.
pub fn published_sans_io_surface_accumulates_events_test() {
  let request =
    anthropic_request.new(
      "claude-test",
      [anthropic_message.user_message("hello")],
      64,
    )
  let http_request =
    anthropic_http.build_streaming_request(
      "fixture-key",
      "https://api.example.test",
      request,
    )
  http_request.url |> should.equal("https://api.example.test/v1/messages")
  http_request.body
  |> string.contains("\"stream\":true")
  |> should.be_true
  http_request.headers
  |> list.contains(#("accept", "text/event-stream"))
  |> should.be_true

  let event =
    "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"x\"}}\n\n"
  let #(events, state) =
    anthropic_handler.process_chunk(
      anthropic_handler.new_streaming_state(),
      string.repeat(event, 40),
    )
  list.length(events) |> should.equal(40)
  list.length(anthropic_handler.get_accumulated_events(state))
  |> should.equal(40)
  anthropic_handler.get_full_text(events)
  |> should.equal(string.repeat("x", 40))
}
