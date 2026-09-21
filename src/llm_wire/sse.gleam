import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm_wire/types

pub type ServerSentEvent {
  ServerSentEvent(
    event: Option(String),
    data: String,
    id: Option(String),
    retry: Option(Int),
  )
}

pub opaque type Framer {
  Framer(
    limits: types.Limits,
    buffer: BitArray,
    event_type: Option(String),
    data_lines: List(String),
    event_id: Option(String),
    retry_ms: Option(Int),
    accumulated_event_bytes: Int,
  )
}

pub fn new(limits: types.Limits) -> Framer {
  Framer(
    limits: limits,
    buffer: <<>>,
    event_type: None,
    data_lines: [],
    event_id: None,
    retry_ms: None,
    accumulated_event_bytes: 0,
  )
}

pub fn feed(
  framer: Framer,
  chunk: BitArray,
) -> Result(#(Framer, List(ServerSentEvent)), types.WireError) {
  let chunk_size = bit_array.byte_size(chunk)
  case chunk_size > framer.limits.chunk_bytes_limit {
    True ->
      Error(types.ResourceLimitExceeded(
        "chunk_bytes_limit",
        framer.limits.chunk_bytes_limit,
        chunk_size,
      ))
    False -> {
      let combined = bit_array.append(framer.buffer, chunk)
      parse_lines(framer, combined, [])
    }
  }
}

pub fn finish(
  framer: Framer,
) -> Result(List(ServerSentEvent), types.WireError) {
  case bit_array.byte_size(framer.buffer) > 0 {
    True -> Error(types.ProtocolError("Incomplete SSE frame at EOF"))
    False ->
      case framer.data_lines {
        [] -> Ok([])
        _ -> {
          let event =
            ServerSentEvent(
              event: framer.event_type,
              data: string.join(list.reverse(framer.data_lines), "\n"),
              id: framer.event_id,
              retry: framer.retry_ms,
            )
          Ok([event])
        }
      }
  }
}

fn parse_lines(
  framer: Framer,
  buffer: BitArray,
  emitted: List(ServerSentEvent),
) -> Result(#(Framer, List(ServerSentEvent)), types.WireError) {
  case extract_line(buffer) {
    EndOfBuffer(remaining) -> {
      let remaining_size = bit_array.byte_size(remaining)
      case remaining_size > framer.limits.line_bytes_limit {
        True ->
          Error(types.ResourceLimitExceeded(
            "line_bytes_limit",
            framer.limits.line_bytes_limit,
            remaining_size,
          ))
        False -> Ok(#(Framer(..framer, buffer: remaining), emitted))
      }
    }
    LineFound(raw_line, remaining) -> {
      let line_size = bit_array.byte_size(raw_line)
      case line_size > framer.limits.line_bytes_limit {
        True ->
          Error(types.ResourceLimitExceeded(
            "line_bytes_limit",
            framer.limits.line_bytes_limit,
            line_size,
          ))
        False -> {
          case bit_array.to_string(raw_line) {
            Error(Nil) ->
              Error(types.ProtocolError("Invalid UTF-8 in SSE stream"))
            Ok(line) -> {
              case process_line(framer, line) {
                Error(e) -> Error(e)
                Ok(#(next_framer, maybe_event)) -> {
                  let next_emitted = case maybe_event {
                    Some(ev) -> list.append(emitted, [ev])
                    None -> emitted
                  }
                  parse_lines(next_framer, remaining, next_emitted)
                }
              }
            }
          }
        }
      }
    }
  }
}

type LineExtract {
  EndOfBuffer(BitArray)
  LineFound(BitArray, BitArray)
}

fn extract_line(buffer: BitArray) -> LineExtract {
  find_line_terminator(buffer, 0)
}

fn find_line_terminator(buffer: BitArray, offset: Int) -> LineExtract {
  case buffer {
    // Check for \r\n
    <<prefix:bytes-size(offset), 13, 10, rest:bits>> -> LineFound(prefix, rest)

    // Check for \r alone, but only if not at end of buffer
    <<prefix:bytes-size(offset), 13, rest:bits>> ->
      case bit_array.byte_size(rest) == 0 {
        // Trailing \r might be the first byte of \r\n across chunks! Leave in buffer.
        True -> EndOfBuffer(buffer)
        False -> LineFound(prefix, rest)
      }

    // Check for \n alone
    <<prefix:bytes-size(offset), 10, rest:bits>> -> LineFound(prefix, rest)

    // Advance 1 byte
    <<_:bytes-size(offset), _:size(8), _:bits>> ->
      find_line_terminator(buffer, offset + 1)

    // Reached end of buffer without line terminator
    _ -> EndOfBuffer(buffer)
  }
}

fn process_line(
  framer: Framer,
  line: String,
) -> Result(#(Framer, Option(ServerSentEvent)), types.WireError) {
  case line {
    // Blank line indicates event boundary
    "" -> {
      case framer.data_lines {
        [] ->
          case framer.event_type, framer.event_id {
            None, None -> Ok(#(framer, None))
            _, _ -> {
              let event =
                ServerSentEvent(
                  event: framer.event_type,
                  data: "",
                  id: framer.event_id,
                  retry: framer.retry_ms,
                )
              let reset_framer =
                Framer(
                  ..framer,
                  event_type: None,
                  data_lines: [],
                  event_id: None,
                  retry_ms: None,
                  accumulated_event_bytes: 0,
                )
              Ok(#(reset_framer, Some(event)))
            }
          }
        _ -> {
          let event =
            ServerSentEvent(
              event: framer.event_type,
              data: string.join(list.reverse(framer.data_lines), "\n"),
              id: framer.event_id,
              retry: framer.retry_ms,
            )
          let reset_framer =
            Framer(
              ..framer,
              event_type: None,
              data_lines: [],
              event_id: None,
              retry_ms: None,
              accumulated_event_bytes: 0,
            )
          Ok(#(reset_framer, Some(event)))
        }
      }
    }

    // Comment line
    ":" <> _ -> Ok(#(framer, None))

    // Field line
    _ -> {
      let #(field, value) = parse_field(line)
      case field {
        "data" -> {
          let added_bytes = string.byte_size(value) + 1
          let new_total = framer.accumulated_event_bytes + added_bytes
          case new_total > framer.limits.event_bytes_limit {
            True ->
              Error(types.ResourceLimitExceeded(
                "event_bytes_limit",
                framer.limits.event_bytes_limit,
                new_total,
              ))
            False -> {
              let next_framer =
                Framer(
                  ..framer,
                  data_lines: [value, ..framer.data_lines],
                  accumulated_event_bytes: new_total,
                )
              Ok(#(next_framer, None))
            }
          }
        }
        "event" -> Ok(#(Framer(..framer, event_type: Some(value)), None))
        "id" -> Ok(#(Framer(..framer, event_id: Some(value)), None))
        "retry" -> {
          case int.parse(value) {
            Ok(ms) -> Ok(#(Framer(..framer, retry_ms: Some(ms)), None))
            Error(Nil) -> Ok(#(framer, None))
          }
        }
        _ -> Ok(#(framer, None))
      }
    }
  }
}

fn parse_field(line: String) -> #(String, String) {
  case string.split_once(line, ":") {
    Ok(#(field, rest)) -> {
      let value = case string.starts_with(rest, " ") {
        True -> string.drop_start(rest, 1)
        False -> rest
      }
      #(field, value)
    }
    Error(Nil) -> #(line, "")
  }
}
