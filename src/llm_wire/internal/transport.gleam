import gleam/erlang/process
import gleam/result
import llm_wire/api
import llm_wire/types

pub type TransportHandle {
  TransportHandle(
    request_more: fn() -> Nil,
    close: fn() -> Nil,
    owner_pid: process.Pid,
  )
}

pub fn owner_pid(handle: TransportHandle) -> process.Pid {
  handle.owner_pid
}

@external(erlang, "llm_wire_gun_ffi", "now_ms")
pub fn monotonic_millis() -> Int

pub fn connect_and_stream(
  prepared: api.PreparedCall,
  overall_timeout_ms: Int,
  tls_mode: types.TlsMode,
  max_header_bytes: Int,
  max_chunk_bytes: Int,
  owner_pid: process.Pid,
  on_chunk: fn(BitArray) -> Nil,
  on_eof: fn() -> Nil,
  on_error: fn(String) -> Nil,
  on_request_sent: fn() -> Nil,
) -> Result(TransportHandle, types.WireError) {
  use #(transport_port, transport_pid) <- result.try(
    api.connect_prepared_and_stream(
      prepared,
      overall_timeout_ms,
      tls_mode,
      max_header_bytes,
      max_chunk_bytes,
      owner_pid,
      on_chunk,
      on_eof,
      on_error,
      on_request_sent,
    ),
  )
  Ok(TransportHandle(
    request_more: transport_port.request_more,
    close: transport_port.close,
    owner_pid: transport_pid,
  ))
}
