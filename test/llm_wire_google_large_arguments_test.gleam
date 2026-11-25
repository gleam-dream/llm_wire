import gleam/erlang/process
import google_part_encoding_bench
import llm_wire/internal/google
import llm_wire/internal/limits
import llm_wire/message

/// One event may carry function-call arguments with a very large array. The
/// reducer runs inside the call's owner, which cannot serve its timers or a
/// close while it works, so reading the event must stay proportional to its
/// size. 80,000 elements fit the default event limit and take milliseconds
/// when the work is linear.
pub fn google_large_argument_array_is_read_in_bounded_time_test() {
  let done = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      let reducer = google.new(limits.default())
      process.send(
        done,
        google.step(reducer, google_part_encoding_bench.event(80_000)),
      )
    })
  let read = process.receive(done, 2000)
  process.kill(worker)
  let assert Ok(Ok(#(_, [message.ToolArgumentsDelta(call_id: "call_1", ..)]))) =
    read
}
