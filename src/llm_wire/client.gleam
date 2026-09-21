import llm_wire/owner
import llm_wire/transport
import llm_wire/types

pub fn open_openai_stream(
  host: String,
  port: Int,
  path: String,
  api_key: types.ApiKey,
  limits: types.Limits,
  deadlines: types.Deadlines,
  body: String,
) -> Result(owner.Stream, types.WireError) {
  let headers = [
    #("Authorization", "Bearer " <> types.api_key_expose(api_key)),
    #("Content-Type", "application/json"),
    #("Accept", "text/event-stream"),
  ]

  let dummy_transport =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })

  case owner.start_openai_stream(limits, deadlines, dummy_transport) {
    Error(err) -> Error(err)
    Ok(stream) -> {
      let on_chunk = fn(chunk) { owner.feed_chunk(stream, chunk) }
      let on_eof = fn() { owner.feed_eof(stream) }
      let on_error = fn(err) { owner.feed_error(stream, err) }

      case
        transport.connect_and_stream(
          host,
          port,
          path,
          headers,
          body,
          deadlines.read_timeout_ms,
          deadlines.read_timeout_ms,
          on_chunk,
          on_eof,
          on_error,
        )
      {
        Error(err) -> {
          let _ = owner.close(stream)
          Error(err)
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

pub fn open_anthropic_stream(
  host: String,
  port: Int,
  path: String,
  api_key: types.ApiKey,
  limits: types.Limits,
  deadlines: types.Deadlines,
  body: String,
) -> Result(owner.Stream, types.WireError) {
  let headers = [
    #("x-api-key", types.api_key_expose(api_key)),
    #("anthropic-version", "2023-06-01"),
    #("Content-Type", "application/json"),
    #("Accept", "text/event-stream"),
  ]

  let dummy_transport =
    owner.TransportPort(request_more: fn() { Nil }, close: fn() { Nil })

  case owner.start_anthropic_stream(limits, deadlines, dummy_transport) {
    Error(err) -> Error(err)
    Ok(stream) -> {
      let on_chunk = fn(chunk) { owner.feed_chunk(stream, chunk) }
      let on_eof = fn() { owner.feed_eof(stream) }
      let on_error = fn(err) { owner.feed_error(stream, err) }

      case
        transport.connect_and_stream(
          host,
          port,
          path,
          headers,
          body,
          deadlines.read_timeout_ms,
          deadlines.read_timeout_ms,
          on_chunk,
          on_eof,
          on_error,
        )
      {
        Error(err) -> {
          let _ = owner.close(stream)
          Error(err)
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
