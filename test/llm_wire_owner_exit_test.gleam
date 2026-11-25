import gleam/erlang/process
import gleam/option.{None}
import http_test_helpers
import llm_wire
import llm_wire/error
import llm_wire/internal/config
import llm_wire/internal/limits
import llm_wire/internal/owner
import llm_wire/internal/stream_types
import llm_wire/message
import llm_wire/provider
import llm_wire/testing
import owner_provider_helper

type Report(value) {
  Returned(value)
  CallerDied
}

/// Run `work` in a process of its own and report what it returned, or that
/// the process died before it returned.
fn in_caller(work: fn() -> value) -> Report(value) {
  let returned = process.new_subject()
  let caller = process.spawn_unlinked(fn() { process.send(returned, work()) })
  let monitor = process.monitor(caller)
  let report =
    process.new_selector()
    |> process.select_map(returned, Returned)
    |> process.select_specific_monitor(monitor, fn(_) { CallerDied })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  // The caller sends its result before it exits, so a result already sent
  // wins over the exit that follows it.
  case report, process.receive(returned, 0) {
    CallerDied, Ok(value) -> Returned(value)
    _, _ -> report
  }
}

/// A custom reducer that raises ends the call's owner abnormally. The caller
/// receives a typed failure; the owner's exit does not reach it.
pub fn a_crashing_owner_fails_the_call_without_ending_the_caller_test() {
  let settings =
    provider.new(
      message.Custom("crashing-reducer"),
      "https://provider.invalid",
      fn(_request, _tools, _format) { Ok(provider.encoded("/events", "{}")) },
      fn() {
        provider.reducer(
          Nil,
          fn(_, _) { panic as "controlled reducer exception" },
          fn(_) { None },
        )
      },
    )
    |> provider.config
  let assert Ok(call) =
    llm_wire.prepare(
      settings,
      llm_wire.request("fixture", [message.User("hi")]),
    )
  use client <- http_test_helpers.with_script([
    testing.exchange(call, testing.events(["event: text\ndata: fail\n\n"])),
  ])
  let assert Returned(Error(failure)) =
    in_caller(fn() { llm_wire.run(client, call) })
  assert failure.error == error.Stopped
  assert failure.sent == llm_wire.MaybeSent
}

/// The owner is killed while its creator waits for the next event, as `close`
/// from a copied handle kills an owner that does not answer. The creator's
/// read returns; the creator does not die with the owner.
pub fn killing_the_owner_fails_a_waiting_read_without_ending_the_creator_test() {
  let started = process.new_subject()
  let returned = process.new_subject()
  let creator =
    process.spawn_unlinked(fn() {
      let assert Ok(stream) =
        owner_provider_helper.start_openai_stream(
          limits.default(),
          config.default_timeouts(),
          owner.TransportPort(fn() { Nil }, fn() { Nil }, fn() { Nil }),
        )
      let assert Ok(pid) = owner.owner_pid(stream)
      process.send(started, pid)
      process.send(returned, owner.next(stream, None))
    })
  let monitor = process.monitor(creator)
  let assert Ok(owner_pid) = process.receive(started, 1000)
  process.kill(owner_pid)
  let assert Ok(Returned(read)) =
    process.new_selector()
    |> process.select_map(returned, Returned)
    |> process.select_specific_monitor(monitor, fn(_) { CallerDied })
    |> process.selector_receive(1000)
  // The kill can land before the read is registered or after it.
  assert read == Error(stream_types.OwnerUnavailable)
    || read == Error(stream_types.StreamClosed)
}

/// A creator that is killed still takes its owner with it, and the owner
/// releases the transport first.
pub fn killing_the_creator_ends_the_owner_and_releases_the_transport_test() {
  let started = process.new_subject()
  let released = process.new_subject()
  let creator =
    process.spawn_unlinked(fn() {
      let assert Ok(stream) =
        owner_provider_helper.start_openai_stream(
          limits.default(),
          config.default_timeouts(),
          owner.TransportPort(fn() { Nil }, fn() { Nil }, fn() {
            process.send(released, Nil)
          }),
        )
      let assert Ok(pid) = owner.owner_pid(stream)
      process.send(started, pid)
      process.sleep_forever()
    })
  let assert Ok(owner_pid) = process.receive(started, 1000)
  let monitor = process.monitor(owner_pid)
  process.kill(creator)
  let assert Ok(Nil) = process.receive(released, 1000)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
}
