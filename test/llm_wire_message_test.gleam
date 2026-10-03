//// Values a request is built from. `llm_wire/types` is gone: model names,
//// call ids, keys and endpoints are plain strings checked by
//// `llm_wire.prepare`, tool names are checked by `tool.check_name`, and
//// limits and timeouts are set on the configuration.

import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun/testing as http_testing
import llm_wire
import llm_wire/error
import llm_wire/internal/api
import llm_wire/internal/call
import llm_wire/internal/config
import llm_wire/limit
import llm_wire/message
import llm_wire/openai
import llm_wire/testing
import llm_wire/tool
import tool_fixtures

fn hello(model: String) -> llm_wire.Request(String) {
  llm_wire.request(model, [llm_wire.user("hello")])
}

/// A history whose assistant turn made one call with `id`.
fn history_with_call(id: String) -> llm_wire.Request(String) {
  llm_wire.request("m", [
    llm_wire.user("calculate"),
    message.Assistant(message.AssistantTurn(
      provider: None,
      text: "",
      calls: [message.tool_call(id, "calc", "{}")],
      response_id: None,
      provider_data: None,
    )),
    message.ToolResult(id, "14"),
  ])
}

pub fn model_id_validation_test() {
  llm_wire.prepare(testing.config(), hello("gpt-4o")) |> should.be_ok
  let assert Error(error.InvalidSetting(error.Model, _)) =
    llm_wire.prepare(testing.config(), hello(""))
}

pub fn call_id_validation_test() {
  // Call ids are plain strings; `prepare` refuses an empty one in history.
  llm_wire.prepare(testing.config(), history_with_call("call_123"))
  |> should.be_ok
  llm_wire.prepare(testing.config(), history_with_call(""))
  |> should.equal(Error(error.InvalidRequest(error.InvalidCallId(""))))
}

pub fn tool_name_validation_test() {
  tool.check_name("get_weather") |> should.equal(Ok(Nil))
  tool.check_name("") |> should.equal(Error(tool.EmptyName))
}

pub fn tool_name_accepts_the_portable_provider_grammar_test() {
  let at_limit = string.repeat("a", 64)
  tool.check_name(at_limit) |> should.equal(Ok(Nil))
  tool_fixtures.string_field_tool(at_limit, "q")
  |> tool.name
  |> should.equal(at_limit)
  tool.check_name("Get-Weather_v2") |> should.equal(Ok(Nil))
  tool_fixtures.string_field_tool("Get-Weather_v2", "q")
  |> tool.name
  |> should.equal("Get-Weather_v2")
}

pub fn tool_name_rejects_names_providers_refuse_test() {
  tool.check_name(string.repeat("a", 65))
  |> should.equal(Error(tool.NameTooLong(65)))
  tool.check_name("functions.lookup")
  |> should.equal(Error(tool.InvalidCharacter(".")))
  tool.check_name("look up")
  |> should.equal(Error(tool.InvalidCharacter(" ")))
  tool.check_name(" lookup")
  |> should.equal(Error(tool.InvalidCharacter(" ")))
  tool.check_name("café")
  |> should.equal(Error(tool.InvalidCharacter("é")))
}

pub fn manual_tool_call_defaults_provider_metadata_test() {
  let made = message.tool_call("call-1", "lookup", "{\"query\":\"gleam\"}")
  made.provider_id |> should.equal(None)
  made.provider_state |> should.equal(None)
  let restored = message.ToolCall(..made, provider_id: Some("provider-1"))
  restored.provider_id |> should.equal(Some("provider-1"))
}

pub fn api_key_validation_test() {
  // `types.reveal_api_key` is gone: the key is read only inside the
  // adapter's header closure. It reaches the admitted request exactly.
  let assert Ok(prepared) =
    llm_wire.prepare(openai.new("sk-secret-12345") |> openai.config, hello("m"))
  api.http_request(call.prepared_call(prepared)).headers
  |> list.contains(#("authorization", "Bearer sk-secret-12345"))
  |> should.be_true
  // HTTP Gun's recorded exchange redacts it.
  http_testing.request(testing.exchange(prepared, testing.text("")))
  |> string.inspect
  |> string.contains("sk-secret-12345")
  |> should.be_false
  let assert Error(error.InvalidSetting(error.ApiKey, _)) =
    llm_wire.prepare(openai.new("") |> openai.config, hello("m"))
}

pub fn endpoint_validation_test() {
  let prepare_at = fn(endpoint) {
    llm_wire.prepare(
      openai.new("k") |> openai.config |> llm_wire.with_endpoint(endpoint),
      hello("m"),
    )
  }
  prepare_at("https://api.openai.com/v1") |> should.be_ok
  prepare_at("http://localhost:8080") |> should.be_ok
  let assert Error(error.InvalidSetting(error.Endpoint, _)) = prepare_at("")
  let assert Error(error.InvalidSetting(error.Endpoint, _)) =
    prepare_at("not-a-url")
}

pub fn limits_validation_test() {
  limit.default(limit.ChunkBytes) |> should.equal(65_536)
  llm_wire.prepare(
    testing.config() |> llm_wire.with_limit(limit.ChunkBytes, 1024),
    hello("m"),
  )
  |> should.be_ok
  let assert Error(error.InvalidSetting(error.LimitSetting(limit.ChunkBytes), _)) =
    llm_wire.prepare(
      testing.config() |> llm_wire.with_limit(limit.ChunkBytes, 0),
      hello("m"),
    )
}

pub fn deadlines_validation_test() {
  // The overall deadline became the whole-call timeout; its default rose
  // from 60 s to 600 s.
  config.default_timeouts().whole_call |> should.equal(Some(600_000))
  llm_wire.prepare(
    testing.config()
      |> llm_wire.with_call_timeout(llm_wire.After(duration.seconds(30))),
    hello("m"),
  )
  |> should.be_ok
  let assert Error(error.InvalidSetting(
    error.TimeoutSetting(error.WholeCall),
    _,
  )) =
    llm_wire.prepare(
      testing.config()
        |> llm_wire.with_call_timeout(llm_wire.After(duration.milliseconds(-1))),
      hello("m"),
    )
}
