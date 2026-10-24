//// Own the HTTP client: start one `http_gun.Client` under the application's
//// supervisor, reach it by name from anywhere, and pass it to LLM Wire. LLM
//// Wire never starts or stops the client.

import gleam/erlang/process
import gleam/io
import gleam/otp/static_supervisor as supervisor
import http_gun
import http_gun/config as http_config

pub fn main() -> Nil {
  let name = process.new_name("llm_wire_usage_http")
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(http_gun.supervised(http_config.default(), name))
    |> supervisor.start

  // The name reaches the client across restarts. Pass it to `llm_wire.run`
  // and `llm_wire.stream` (see `llm_wire_consumer.http_client`).
  let client = http_gun.named(name)
  let assert Ok(_) = http_gun.stats(client)
  io.println("supervised client is running")
}
