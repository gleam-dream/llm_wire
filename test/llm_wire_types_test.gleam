import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import llm_wire/types

pub fn model_id_validation_test() {
  types.model_id("gpt-4o")
  |> should.be_ok

  types.model_id("")
  |> should.be_error
}

pub fn call_id_validation_test() {
  types.call_id("call_123")
  |> should.be_ok

  types.call_id("")
  |> should.be_error
}

pub fn tool_name_validation_test() {
  types.tool_name("get_weather")
  |> should.be_ok

  types.tool_name("")
  |> should.equal(Error(types.EmptyToolName))
}

pub fn tool_name_accepts_the_portable_provider_grammar_test() {
  let at_limit = string.repeat("a", 64)
  let assert Ok(name) = types.tool_name(at_limit)
  types.tool_name_to_string(name) |> should.equal(at_limit)
  let assert Ok(name) = types.tool_name("Get-Weather_v2")
  types.tool_name_to_string(name) |> should.equal("Get-Weather_v2")
}

pub fn tool_name_rejects_names_providers_refuse_test() {
  types.tool_name(string.repeat("a", 65))
  |> should.equal(Error(types.ToolNameTooLong(65)))
  types.tool_name("functions.lookup")
  |> should.equal(Error(types.InvalidToolNameCharacter(".")))
  types.tool_name("look up")
  |> should.equal(Error(types.InvalidToolNameCharacter(" ")))
  types.tool_name(" lookup")
  |> should.equal(Error(types.InvalidToolNameCharacter(" ")))
  types.tool_name("café")
  |> should.equal(Error(types.InvalidToolNameCharacter("é")))
}

pub fn manual_tool_call_defaults_provider_metadata_test() {
  let assert Ok(id) = types.call_id("call-1")
  let assert Ok(name) = types.tool_name("lookup")
  let call = types.tool_call(id, name, "{\"query\":\"gleam\"}")
  call.provider_id |> should.equal(None)
  call.provider_state |> should.equal(None)
  let restored = types.ToolCall(..call, provider_id: Some("provider-1"))
  restored.provider_id |> should.equal(Some("provider-1"))
}

pub fn api_key_validation_test() {
  let assert Ok(key) = types.api_key("sk-secret-12345")
  types.reveal_api_key(key)
  |> should.equal("sk-secret-12345")

  types.api_key("")
  |> should.be_error
}

pub fn endpoint_validation_test() {
  types.endpoint("https://api.openai.com/v1")
  |> should.be_ok

  types.endpoint("http://localhost:8080")
  |> should.be_ok

  types.endpoint("")
  |> should.be_error

  types.endpoint("not-a-url")
  |> should.be_error
}

pub fn limits_validation_test() {
  let limits = types.default_limits()
  limits.chunk_bytes_limit
  |> should.equal(65_536)

  types.validate_limits(types.Limits(..limits, chunk_bytes_limit: 1024))
  |> should.be_ok

  types.validate_limits(types.Limits(..limits, chunk_bytes_limit: 0))
  |> should.be_error
}

pub fn deadlines_validation_test() {
  let deadlines = types.default_deadlines()
  deadlines.overall_timeout_ms
  |> should.equal(60_000)

  types.validate_deadlines(
    types.Deadlines(..deadlines, overall_timeout_ms: 30_000),
  )
  |> should.be_ok

  types.validate_deadlines(types.Deadlines(..deadlines, overall_timeout_ms: -1))
  |> should.be_error
}
