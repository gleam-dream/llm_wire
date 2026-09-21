import gleam/option.{type Option, unwrap}
import llm_wire/api
import llm_wire/internal/transport
import llm_wire/owner
import llm_wire/types

/// Opens only a request that passed the API's local admission path.
/// The prepared value is opaque, so external callers cannot substitute a body,
/// endpoint, tool catalog, or headers at this boundary.
pub fn open_prepared_stream(
  prepared: api.PreparedCall,
  limits: types.Limits,
  deadlines: types.Deadlines,
  tls_override: Option(types.TlsMode),
) -> Result(owner.Stream, types.WireError) {
  let provider = api.prepared_provider(prepared)
  let tools = api.prepared_tools(prepared)
  let prepared_tls_mode = api.prepared_tls_mode(prepared)
  let tls_mode = unwrap(tls_override, prepared_tls_mode)
  open_stream(prepared, provider, limits, deadlines, tools, tls_mode)
}

fn open_stream(
  prepared: api.PreparedCall,
  provider: types.Provider,
  limits: types.Limits,
  deadlines: types.Deadlines,
  tools: List(types.ToolDefinition),
  tls_mode: types.TlsMode,
) -> Result(owner.Stream, types.WireError) {
  let overall_started_ms = transport.monotonic_millis()
  let dummy_transport =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })

  case start_owner(provider, limits, deadlines, dummy_transport, tools) {
    Error(error) -> Error(error)
    Ok(stream) -> {
      case owner.owner_pid(stream) {
        Error(Nil) ->
          Error(types.ConfigurationError("Stream owner unavailable"))
        Ok(owner_pid) -> {
          let on_chunk = fn(chunk) { owner.feed_chunk(stream, chunk) }
          let on_eof = fn() { owner.feed_eof(stream) }
          let on_error = fn(error) { owner.feed_error(stream, error) }
          let on_request_sent = fn() { owner.request_was_sent(stream) }

          case
            transport.connect_and_stream(
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
              Error(error)
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

fn remaining_overall_ms(started_at: Int, timeout_ms: Int) -> Int {
  let elapsed = transport.monotonic_millis() - started_at
  let remaining = timeout_ms - elapsed
  case remaining > 0 {
    True -> remaining
    False -> 1
  }
}

fn start_owner(
  provider: types.Provider,
  limits: types.Limits,
  deadlines: types.Deadlines,
  transport_port: owner.TransportPort,
  tools: List(types.ToolDefinition),
) -> Result(owner.Stream, types.WireError) {
  case provider {
    types.OpenAI ->
      owner.start_openai_stream_with_tools(
        limits,
        deadlines,
        transport_port,
        tools,
      )
    types.Anthropic ->
      owner.start_anthropic_stream_with_tools(
        limits,
        deadlines,
        transport_port,
        tools,
      )
    types.Google ->
      Error(types.ConfigurationError("Google streaming is not implemented"))
  }
}
