// snips-start: first-call
import gleam/io
import http_gun
import http_gun/config as http_config
import llm_wire
import llm_wire/error
import llm_wire/openai

pub fn main() -> Nil {
  let config = openai.new("sk-...") |> openai.config
  let request = llm_wire.request("gpt-5", [llm_wire.user("Hello")])
  case llm_wire.prepare(config, request) {
    Error(problem) -> io.println(error.describe_prepare_error(problem))
    Ok(prepared) ->
      case http_gun.start(http_config.default()) {
        Error(problem) -> io.println(http_gun.describe_start_error(problem))
        Ok(client) -> {
          let result = llm_wire.run(client, prepared)
          http_gun.stop(client)
          case result {
            Ok(llm_wire.Answer(text:, ..)) -> io.println(text)
            Ok(_) -> io.println("no final answer")
            Error(failure) -> io.println(llm_wire.describe_failure(failure))
          }
        }
      }
  }
}
// snips-end: first-call
