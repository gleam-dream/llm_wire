//// Tools and the conversation: declare tools from a codec, a contract or a
//// JSON Schema, report invalid tool calls, and persist history and turns.

import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/list
import json/blueprint/codec
import json/blueprint/contract
import llm_wire
import llm_wire/message
import llm_wire/openai
import llm_wire/testing
import llm_wire/tool
import usage_support.{prepared, scripted}

fn city_codec() -> codec.Codec(String) {
  use city <- codec.field("city", codec.string(), get: fn(city) { city })
  codec.success(city)
}

pub fn main() -> Nil {
  // `tool.new` is for declarations in source code; `from_contract` and
  // `from_json_schema` take runtime data and return a typed error.
  let declared = tool.new("temperature", "Current temperature", city_codec())
  let assert Ok(city_contract) = contract.from_codec(city_codec())
  let assert Ok(from_contract) =
    tool.from_contract("lookup", "Lookup", city_contract)
  let assert Ok(from_schema) =
    tool.from_json_schema(
      "search",
      "Search",
      json.object([
        #("type", json.string("object")),
        #(
          "properties",
          json.object([#("q", json.object([#("type", json.string("string"))]))]),
        ),
        #("required", json.array(["q"], json.string)),
        #("additionalProperties", json.bool(False)),
      ]),
    )

  let config = openai.new("sk-example") |> openai.config
  let request =
    llm_wire.request("gpt-5", [llm_wire.user("How warm is Paris?")])
    |> llm_wire.with_tools([declared, from_contract, from_schema])
  let call = prepared(config, request)

  // The model asks for a tool; the caller answers it and appends the turn.
  let wants_tool =
    testing.events_for(
      message.OpenAI,
      testing.tool_calls("", [
        testing.tool_call("call_1", "temperature", "{\"city\":\"Paris\"}"),
      ]),
    )
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) = {
    use client <- scripted([testing.exchange(call, wants_tool)])
    llm_wire.run(client, call)
  }
  let assert [tool_call] = turn.calls
  let assert Ok("Paris") = tool.decode_arguments(tool_call, city_codec())
  let history = [
    llm_wire.user("How warm is Paris?"),
    message.Assistant(turn),
    llm_wire.tool_result(tool_call, "21"),
  ]

  // Persist a conversation as JSON and read it back unchanged.
  let stored = json.to_string(json.array(history, message.to_json))
  let assert Ok(restored) = json.parse(stored, decode.list(message.decoder()))
  let assert True = restored == history
  io.println("stored " <> int_string(list.length(restored)) <> " messages")

  // A turn persists on its own, or as text and calls kept by the application.
  let turn_json = json.to_string(message.turn_to_json(turn))
  let assert Ok(same_turn) = json.parse(turn_json, message.turn_decoder())
  let assert True = same_turn == turn
  let replay_json = json.to_string(message.turn_replay_to_json(turn))
  let assert Ok(replayed) =
    json.parse(replay_json, message.turn_replay_decoder(turn.text, turn.calls))
  let assert True = replayed == turn

  // With `ReportInvalidToolCalls`, a call to an unknown tool comes back with
  // the others and is listed in `issues`.
  let lenient =
    config |> llm_wire.with_tool_call_checks(tool.ReportInvalidToolCalls)
  let lenient_call = prepared(lenient, request)
  let unknown =
    testing.events_for(
      message.OpenAI,
      testing.tool_calls("", [testing.tool_call("call_2", "nope", "{}")]),
    )
  let assert Ok(llm_wire.NeedsTools(issues: [issue], ..)) = {
    use client <- scripted([testing.exchange(lenient_call, unknown)])
    llm_wire.run(client, lenient_call)
  }
  io.println("issue: " <> tool.describe_issue(issue))
}

fn int_string(value: Int) -> String {
  json.to_string(json.int(value))
}
