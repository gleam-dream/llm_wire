pub type Socket

pub type ListenSocket

@external(erlang, "llm_wire_tcp_ffi", "listen")
pub fn listen(port: Int) -> Result(#(ListenSocket, Int), String)

@external(erlang, "llm_wire_tcp_ffi", "accept")
pub fn accept(listener: ListenSocket, timeout_ms: Int) -> Result(Socket, String)

@external(erlang, "llm_wire_tcp_ffi", "connect")
pub fn connect(
  host: String,
  port: Int,
  timeout_ms: Int,
) -> Result(Socket, String)

@external(erlang, "llm_wire_tcp_ffi", "send")
pub fn send(socket: Socket, data: BitArray) -> Result(Nil, String)

@external(erlang, "llm_wire_tcp_ffi", "recv")
pub fn recv(
  socket: Socket,
  length: Int,
  timeout_ms: Int,
) -> Result(BitArray, String)

@external(erlang, "llm_wire_tcp_ffi", "close")
pub fn close(socket: Socket) -> Nil

@external(erlang, "llm_wire_tcp_ffi", "close")
pub fn close_listener(listener: ListenSocket) -> Nil
