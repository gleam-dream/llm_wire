import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import llm_wire/tcp
import llm_wire/types

pub type TransportHandle {
  TransportHandle(request_more: fn() -> Nil, close: fn() -> Nil)
}

type ReaderMessage {
  CreditRequested
  CloseRequested
}

pub fn connect_and_stream(
  host: String,
  port: Int,
  path: String,
  headers: List(#(String, String)),
  body: String,
  connect_timeout_ms: Int,
  read_timeout_ms: Int,
  on_chunk: fn(BitArray) -> Nil,
  on_eof: fn() -> Nil,
  on_error: fn(String) -> Nil,
) -> Result(TransportHandle, types.WireError) {
  case tcp.connect(host, port, connect_timeout_ms) {
    Error(err) ->
      Error(types.TransportError("Failed to connect to " <> host <> ": " <> err))
    Ok(socket) -> {
      let req_lines = [
        "POST " <> path <> " HTTP/1.1",
        "Host: " <> host <> ":" <> string.inspect(port),
        "Connection: close",
        "Content-Length: " <> string.inspect(string.byte_size(body)),
        ..list.map(headers, fn(h) { h.0 <> ": " <> h.1 })
      ]
      let req_payload = string.join(req_lines, "\r\n") <> "\r\n\r\n" <> body
      let req_bits = bit_array.from_string(req_payload)

      case tcp.send(socket, req_bits) {
        Error(err) -> {
          tcp.close(socket)
          Error(types.TransportError("Failed to send request: " <> err))
        }
        Ok(Nil) -> {
          // Read headers
          case read_http_headers(socket, <<>>, read_timeout_ms) {
            Error(err) -> {
              tcp.close(socket)
              Error(err)
            }
            Ok(#(status_code, remaining_bytes)) -> {
              case status_code {
                200 -> {
                  // If headers read already captured some body bytes, deliver them
                  case bit_array.byte_size(remaining_bytes) > 0 {
                    True -> on_chunk(remaining_bytes)
                    False -> Nil
                  }

                  let reader_subject =
                    spawn_reader(
                      socket,
                      read_timeout_ms,
                      on_chunk,
                      on_eof,
                      on_error,
                    )

                  Ok(
                    TransportHandle(
                      request_more: fn() {
                        process.send(reader_subject, CreditRequested)
                      },
                      close: fn() {
                        process.send(reader_subject, CloseRequested)
                        tcp.close(socket)
                      },
                    ),
                  )
                }
                _ -> {
                  // Non-200 HTTP status
                  let body_str = case bit_array.to_string(remaining_bytes) {
                    Ok(s) -> s
                    Error(Nil) -> ""
                  }
                  tcp.close(socket)
                  Error(types.HttpStatusError(status_code, body_str))
                }
              }
            }
          }
        }
      }
    }
  }
}

fn read_http_headers(
  socket: tcp.Socket,
  buffer: BitArray,
  timeout_ms: Int,
) -> Result(#(Int, BitArray), types.WireError) {
  case find_double_crlf(buffer, 0) {
    Some(#(header_bits, body_bits)) -> {
      case bit_array.to_string(header_bits) {
        Error(Nil) ->
          Error(types.ProtocolError("Invalid UTF-8 in HTTP headers"))
        Ok(header_str) -> parse_status_code(header_str, body_bits)
      }
    }
    None -> {
      case tcp.recv(socket, 0, timeout_ms) {
        Error("closed") ->
          Error(types.TransportError(
            "Connection closed before HTTP headers complete",
          ))
        Error("timeout") -> Error(types.DeadlineExceeded(types.ReadDeadline))
        Error(err) ->
          Error(types.TransportError("Socket error reading headers: " <> err))
        Ok(chunk) -> {
          let updated_buffer = bit_array.append(buffer, chunk)
          read_http_headers(socket, updated_buffer, timeout_ms)
        }
      }
    }
  }
}

fn find_double_crlf(
  buffer: BitArray,
  offset: Int,
) -> Option(#(BitArray, BitArray)) {
  case buffer {
    <<prefix:bytes-size(offset), 13, 10, 13, 10, rest:bits>> ->
      Some(#(prefix, rest))
    <<prefix:bytes-size(offset), 10, 10, rest:bits>> -> Some(#(prefix, rest))
    <<_:bytes-size(offset), _:size(8), _:bits>> ->
      find_double_crlf(buffer, offset + 1)
    _ -> None
  }
}

fn parse_status_code(
  header_str: String,
  body_bits: BitArray,
) -> Result(#(Int, BitArray), types.WireError) {
  case string.split(header_str, "\r\n") {
    [status_line, ..] -> {
      // e.g. "HTTP/1.1 200 OK"
      case string.split(status_line, " ") {
        [_, code_str, ..] -> {
          case int.parse(code_str) {
            Ok(code) -> Ok(#(code, body_bits))
            Error(Nil) ->
              Error(types.ProtocolError(
                "Invalid HTTP status line: " <> status_line,
              ))
          }
        }
        _ ->
          Error(types.ProtocolError(
            "Malformed HTTP status line: " <> status_line,
          ))
      }
    }
    _ -> Error(types.ProtocolError("Empty HTTP response headers"))
  }
}

type DrainResult {
  Credits(Int)
  ShouldClose
}

fn spawn_reader(
  socket: tcp.Socket,
  read_timeout_ms: Int,
  on_chunk: fn(BitArray) -> Nil,
  on_eof: fn() -> Nil,
  on_error: fn(String) -> Nil,
) -> process.Subject(ReaderMessage) {
  let parent_inbox = process.new_subject()
  process.spawn_unlinked(fn() {
    let reader_subject = process.new_subject()
    process.send(parent_inbox, reader_subject)
    reader_loop(
      reader_subject,
      socket,
      0,
      read_timeout_ms,
      on_chunk,
      on_eof,
      on_error,
    )
  })
  let assert Ok(reader_subject) = process.receive(parent_inbox, 5000)
  reader_subject
}

fn reader_loop(
  self_subject: process.Subject(ReaderMessage),
  socket: tcp.Socket,
  credits: Int,
  read_timeout_ms: Int,
  on_chunk: fn(BitArray) -> Nil,
  on_eof: fn() -> Nil,
  on_error: fn(String) -> Nil,
) -> Nil {
  case credits > 0 {
    True -> {
      // We have credit, read next chunk from socket
      case tcp.recv(socket, 0, read_timeout_ms) {
        Ok(chunk) -> {
          on_chunk(chunk)
          // Drain any waiting credit messages
          case drain_credits(self_subject, credits - 1) {
            ShouldClose -> tcp.close(socket)
            Credits(new_credits) ->
              reader_loop(
                self_subject,
                socket,
                new_credits,
                read_timeout_ms,
                on_chunk,
                on_eof,
                on_error,
              )
          }
        }
        Error("closed") -> {
          on_eof()
          tcp.close(socket)
        }
        Error("timeout") -> {
          // Timeout waiting for server bytes with credit, keep credit and loop
          reader_loop(
            self_subject,
            socket,
            credits,
            read_timeout_ms,
            on_chunk,
            on_eof,
            on_error,
          )
        }
        Error(err) -> {
          on_error(err)
          tcp.close(socket)
        }
      }
    }
    False -> {
      // Waiting for credit from consumer
      case process.receive(self_subject, 60_000) {
        Ok(CreditRequested) -> {
          case drain_credits(self_subject, 1) {
            ShouldClose -> tcp.close(socket)
            Credits(total_credits) ->
              reader_loop(
                self_subject,
                socket,
                total_credits,
                read_timeout_ms,
                on_chunk,
                on_eof,
                on_error,
              )
          }
        }
        Ok(CloseRequested) -> {
          tcp.close(socket)
        }
        Error(Nil) -> {
          // Keep waiting for credit
          reader_loop(
            self_subject,
            socket,
            0,
            read_timeout_ms,
            on_chunk,
            on_eof,
            on_error,
          )
        }
      }
    }
  }
}

fn drain_credits(
  subject: process.Subject(ReaderMessage),
  accumulated: Int,
) -> DrainResult {
  case process.receive(subject, 0) {
    Ok(CreditRequested) -> drain_credits(subject, accumulated + 1)
    Ok(CloseRequested) -> ShouldClose
    Error(Nil) -> Credits(accumulated)
  }
}
