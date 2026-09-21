import gleam/option.{None}
import gleeunit/should
import llm_wire

pub fn root_facade_constructs_and_prepares_a_call_without_types_module_test() {
  let assert Ok(key) = llm_wire.api_key("test-key")
  let assert Ok(endpoint) = llm_wire.endpoint("https://api.example.test/v1")
  let assert Ok(model) = llm_wire.model_id("gpt-test")
  let assert Ok(call_id) = llm_wire.call_id("call-1")
  let config = llm_wire.openai_config(key, endpoint, None, None)
  let request = llm_wire.new_request(model, [llm_wire.UserMessage("hello")])
  let assert Ok(prepared) =
    llm_wire.prepare(config, request, llm_wire.default_limits())

  llm_wire.prepared_provider(prepared) |> should.equal(llm_wire.OpenAI)
  llm_wire.ToolResult(call_id, "done")
  |> should.equal(llm_wire.ToolResult(call_id, "done"))
}
