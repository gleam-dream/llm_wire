import gleam/erlang/process
import gleam/option.{type Option, None, unwrap}
import gleam/result
import llm_wire/internal/api
import llm_wire/internal/owner
import llm_wire/internal/tls
import llm_wire/internal/transport
import llm_wire/provider
import llm_wire/types

/// An opening failure retains what the library knows about request delivery.
pub type OpenFailure {
  OpenFailure(error: types.WireError, retry: types.RetryEvidence)
}

/// Opens only a request that passed the API's local admission path.
/// The prepared value is opaque, so external callers cannot substitute a body,
/// endpoint, tool catalog, or headers at this boundary.
pub fn open_prepared_stream(
  prepared: api.PreparedCall,
  limits: types.Limits,
  deadlines: types.Deadlines,
  tls_override: Option(tls.TlsMode),
) -> Result(owner.Stream, OpenFailure) {
  open_prepared_stream_with_pool(
    prepared,
    limits,
    deadlines,
    tls_override,
    None,
  )
}

pub fn open_prepared_stream_with_pool(
  prepared: api.PreparedCall,
  limits: types.Limits,
  deadlines: types.Deadlines,
  tls_override: Option(tls.TlsMode),
  pool_pid: Option(process.Pid),
) -> Result(owner.Stream, OpenFailure) {
  let tools = api.prepared_tools(prepared)
  let prepared_tls_mode = api.prepared_tls_mode(prepared)
  let tls_mode = unwrap(tls_override, prepared_tls_mode)
  use Nil <- result.try(
    api.validate_prepared_transport(prepared, tls_mode)
    |> result.map_error(before_request),
  )
  open_stream(prepared, limits, deadlines, tools, tls_mode, pool_pid)
}

fn open_stream(
  prepared: api.PreparedCall,
  limits: types.Limits,
  deadlines: types.Deadlines,
  tools: List(types.ToolDefinition),
  tls_mode: tls.TlsMode,
  pool_pid: Option(process.Pid),
) -> Result(owner.Stream, OpenFailure) {
  let overall_started_ms = transport.monotonic_millis()
  let dummy_transport =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })

  case start_owner(prepared, limits, deadlines, dummy_transport, tools) {
    Error(error) -> Error(error)
    Ok(stream) -> {
      case owner.owner_pid(stream) {
        Error(Nil) ->
          Error(
            before_request(types.ConfigurationError("Stream owner unavailable")),
          )
        Ok(owner_pid) -> {
          let on_chunk = fn(chunk) { owner.feed_chunk(stream, chunk) }
          let on_eof = fn() { owner.feed_eof(stream) }
          let on_error = fn(error) { owner.feed_error(stream, error) }
          let on_request_sent = fn() { owner.request_was_sent(stream) }

          case
            transport.connect_and_stream_with_pool(
              pool_pid,
              prepared,
              remaining_overall_ms(
                overall_started_ms,
                deadlines.overall_timeout_ms,
              ),
              tls_mode,
              16_384,
              limits.chunk_bytes_limit,
              owner_pid,
              on_chunk,
              on_eof,
              on_error,
              on_request_sent,
            )
          {
            Error(error) -> {
              let _ = owner.close(stream)
              Error(after_transport_attempt(error))
            }
            Ok(handle) -> {
              let real_transport =
                owner.TransportPort(
                  request_more: handle.request_more,
                  close: handle.close,
                )
              owner.attach_transport(stream, real_transport)
              Ok(stream)
            }
          }
        }
      }
    }
  }
}

fn before_request(error: types.WireError) -> OpenFailure {
  OpenFailure(error, types.initial_retry_evidence())
}

fn after_transport_attempt(error: types.WireError) -> OpenFailure {
  let response_bytes = case error {
    types.HttpStatusError(_, _, _) -> True
    _ -> False
  }
  OpenFailure(
    error,
    types.RetryEvidence(
      types.RequestMayHaveReachedProvider,
      response_bytes,
      False,
    ),
  )
}

fn remaining_overall_ms(started_at: Int, timeout_ms: Int) -> Int {
  let elapsed = transport.monotonic_millis() - started_at
  let remaining = timeout_ms - elapsed
  case remaining > 0 {
    True -> remaining
    False -> 1
  }
}

fn start_owner(
  prepared: api.PreparedCall,
  limits: types.Limits,
  deadlines: types.Deadlines,
  transport_port: owner.TransportPort,
  tools: List(types.ToolDefinition),
) -> Result(owner.Stream, OpenFailure) {
  use adapter <- result.try(
    api.prepared_adapter(prepared) |> result.map_error(before_request),
  )
  use reducer <- result.try(
    provider.new_reducer(adapter, limits, tools)
    |> result.map_error(before_request),
  )
  owner.start_provider_stream(
    provider.identity(adapter),
    reducer,
    limits,
    deadlines,
    transport_port,
    tools,
  )
  |> result.map_error(before_request)
}
