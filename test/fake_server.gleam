import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/string
import llm_wire/tcp

pub type FakeServer {
  FakeServer(port: Int, listener: tcp.ListenSocket)
}

pub fn start() -> Result(FakeServer, String) {
  case tcp.listen(0) {
    Ok(#(listener, port)) -> Ok(FakeServer(port: port, listener: listener))
    Error(err) -> Error(err)
  }
}

pub fn stop(server: FakeServer) -> Nil {
  tcp.close_listener(server.listener)
}

pub fn accept_connection(
  server: FakeServer,
  timeout_ms: Int,
) -> Result(tcp.Socket, String) {
  tcp.accept(server.listener, timeout_ms)
}

pub fn read_request_headers(
  socket: tcp.Socket,
  timeout_ms: Int,
) -> Result(String, String) {
  read_headers_acc(socket, <<>>, timeout_ms)
}

fn read_headers_acc(
  socket: tcp.Socket,
  buffer: BitArray,
  timeout_ms: Int,
) -> Result(String, String) {
  case bit_array.to_string(buffer) {
    Ok(str) -> {
      case string.contains(str, "\r\n\r\n") || string.contains(str, "\n\n") {
        True -> Ok(str)
        False -> read_more_headers(socket, buffer, timeout_ms)
      }
    }
    Error(Nil) -> read_more_headers(socket, buffer, timeout_ms)
  }
}

fn read_more_headers(
  socket: tcp.Socket,
  buffer: BitArray,
  timeout_ms: Int,
) -> Result(String, String) {
  case tcp.recv(socket, 0, timeout_ms) {
    Ok(chunk) -> {
      let updated = bit_array.append(buffer, chunk)
      read_headers_acc(socket, updated, timeout_ms)
    }
    Error(err) -> Error(err)
  }
}

pub fn send_sse_stream(
  socket: tcp.Socket,
  chunks: List(#(Int, BitArray)),
  close_after: Bool,
) -> Result(Nil, String) {
  let header =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
  case tcp.send(socket, bit_array.from_string(header)) {
    Error(err) -> Error(err)
    Ok(Nil) -> {
      let res =
        list.fold(chunks, Ok(Nil), fn(acc, item) {
          case acc {
            Error(e) -> Error(e)
            Ok(Nil) -> {
              let #(delay_ms, data) = item
              case delay_ms > 0 {
                True -> process.sleep(delay_ms)
                False -> Nil
              }
              tcp.send(socket, data)
            }
          }
        })
      case close_after {
        True -> tcp.close(socket)
        False -> Nil
      }
      res
    }
  }
}

pub fn send_http_error(
  socket: tcp.Socket,
  status_code: Int,
  status_text: String,
  body: String,
) -> Result(Nil, String) {
  let header =
    "HTTP/1.1 "
    <> string.inspect(status_code)
    <> " "
    <> status_text
    <> "\r\nContent-Type: application/json\r\nContent-Length: "
    <> string.inspect(string.byte_size(body))
    <> "\r\nRetry-After: 3\r\nConnection: close\r\n\r\n"
    <> body
  let res = tcp.send(socket, bit_array.from_string(header))
  tcp.close(socket)
  res
}

pub fn send_raw_response(
  socket: tcp.Socket,
  response: String,
) -> Result(Nil, String) {
  let result = tcp.send(socket, bit_array.from_string(response))
  tcp.close(socket)
  result
}

pub fn send_chunked_sse_keepalive(
  socket: tcp.Socket,
  payload: String,
) -> Result(Nil, String) {
  let header =
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
  let chunk =
    int.to_base16(string.byte_size(payload))
    <> "\r\n"
    <> payload
    <> "\r\n0\r\n\r\n"
  tcp.send(socket, bit_array.from_string(header <> chunk))
}
