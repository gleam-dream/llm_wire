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
  |> should.be_error
}

pub fn api_key_redaction_test() {
  let assert Ok(key) = types.api_key("sk-secret-12345")
  types.api_key_expose(key)
  |> should.equal("sk-secret-12345")

  types.api_key_redacted(key)
  |> should.equal("[REDACTED]")

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

  types.new_limits(
    chunk_bytes_limit: 1024,
    line_bytes_limit: 512,
    event_bytes_limit: 2048,
    queue_count_limit: 100,
    queue_bytes_limit: 10_000,
    active_blocks_limit: 10,
    text_bytes_per_block_limit: 10_000,
    total_text_bytes_limit: 50_000,
    argument_bytes_per_call_limit: 10_000,
    total_argument_bytes_limit: 50_000,
    extension_bytes_limit: 2048,
  )
  |> should.be_ok

  types.new_limits(
    chunk_bytes_limit: 0,
    line_bytes_limit: 512,
    event_bytes_limit: 2048,
    queue_count_limit: 100,
    queue_bytes_limit: 10_000,
    active_blocks_limit: 10,
    text_bytes_per_block_limit: 10_000,
    total_text_bytes_limit: 50_000,
    argument_bytes_per_call_limit: 10_000,
    total_argument_bytes_limit: 50_000,
    extension_bytes_limit: 2048,
  )
  |> should.be_error
}

pub fn deadlines_validation_test() {
  let deadlines = types.default_deadlines()
  deadlines.overall_timeout_ms
  |> should.equal(60_000)

  types.new_deadlines(
    overall_timeout_ms: 30_000,
    idle_timeout_ms: 5000,
    read_timeout_ms: 1000,
  )
  |> should.be_ok

  types.new_deadlines(
    overall_timeout_ms: -1,
    idle_timeout_ms: 5000,
    read_timeout_ms: 1000,
  )
  |> should.be_error
}
