import gleam/erlang/process
import gleam/option.{type Option, None}
import gleam/result
import llm_wire/internal/api
import llm_wire/internal/tls
import llm_wire/internal/transport_failure
import llm_wire/types

pub type TransportHandle {
  TransportHandle(
    request_more: fn() -> Nil,
    close: fn() -> Nil,
    owner_pid: process.Pid,
  )
}

/// Explicit delivery evidence from a substituted transport's opening phase.
pub type ConnectFailure {
  ConnectFailure(error: types.WireError, retry: types.RetryEvidence)
}

/// Replaces the network connection for one prepared call. `llm_wire/testing`
/// uses it to deliver scripted bytes to the same stream owner, reducer, and
/// session path as a real response; the runtime never opens a socket for it.
pub type Connector {
  Connector(
    connect: fn(
      api.PreparedCall,
      Int,
      process.Pid,
      fn(BitArray) -> Nil,
      fn() -> Nil,
      fn(transport_failure.Failure) -> Nil,
      fn() -> Nil,
    ) -> Result(TransportHandle, ConnectFailure),
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
  tls_mode: tls.TlsMode,
  max_header_bytes: Int,
  max_chunk_bytes: Int,
  owner_pid: process.Pid,
  on_chunk: fn(BitArray) -> Nil,
  on_eof: fn() -> Nil,
  on_error: fn(transport_failure.Failure) -> Nil,
  on_request_sent: fn() -> Nil,
) -> Result(TransportHandle, types.WireError) {
  connect_and_stream_with_pool(
    None,
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
  )
}

pub fn connect_and_stream_with_pool(
  pool_pid: Option(process.Pid),
  prepared: api.PreparedCall,
  overall_timeout_ms: Int,
  tls_mode: tls.TlsMode,
  max_header_bytes: Int,
  max_chunk_bytes: Int,
  owner_pid: process.Pid,
  on_chunk: fn(BitArray) -> Nil,
  on_eof: fn() -> Nil,
  on_error: fn(transport_failure.Failure) -> Nil,
  on_request_sent: fn() -> Nil,
) -> Result(TransportHandle, types.WireError) {
  use #(transport_port, transport_pid) <- result.try(
    api.connect_prepared_and_stream_with_pool(
      pool_pid,
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
