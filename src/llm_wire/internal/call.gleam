//// The facade's opaque values. They live here so `llm_wire/testing` can
//// read a prepared call's admitted HTTP request.

import gleam/option.{type Option}
import json/blueprint/codec
import json/blueprint/contract
import llm_wire/error.{type ValueFailure}
import llm_wire/internal/adapter
import llm_wire/internal/api
import llm_wire/internal/config.{type Config}
import llm_wire/internal/owner
import llm_wire/internal/tool_def.{type Tool}
import llm_wire/message

pub type Decode(o) =
  fn(Option(contract.Contract), String, Int) -> Result(o, ValueFailure)

/// How a request's final text becomes its output.
pub type Output(o) {
  Output(
    /// The output name and its schema, or why the codec has none usable.
    format: Option(
      #(String, Result(#(codec.Schema, contract.Contract), String)),
    ),
    decode: Decode(o),
  )
}

pub opaque type Request(o) {
  Request(view: adapter.Request, tools: List(Tool), output: Output(o))
}

pub fn request(
  view: adapter.Request,
  tools: List(Tool),
  output: Output(o),
) -> Request(o) {
  Request(view:, tools:, output:)
}

pub fn view(request: Request(o)) -> adapter.Request {
  request.view
}

pub fn tools(request: Request(o)) -> List(Tool) {
  request.tools
}

pub fn output(request: Request(o)) -> Output(o) {
  request.output
}

pub fn with_view(request: Request(o), view: adapter.Request) -> Request(o) {
  Request(..request, view:)
}

pub fn with_tools(request: Request(o), tools: List(Tool)) -> Request(o) {
  Request(..request, tools:)
}

pub opaque type Prepared(o) {
  Prepared(
    call: api.PreparedCall,
    config: Config,
    contract: Option(contract.Contract),
    decode: Decode(o),
  )
}

pub fn prepared(
  call: api.PreparedCall,
  config: Config,
  contract: Option(contract.Contract),
  decode: Decode(o),
) -> Prepared(o) {
  Prepared(call:, config:, contract:, decode:)
}

pub fn prepared_call(prepared: Prepared(o)) -> api.PreparedCall {
  prepared.call
}

pub fn prepared_config(prepared: Prepared(o)) -> Config {
  prepared.config
}

pub fn prepared_contract(prepared: Prepared(o)) -> Option(contract.Contract) {
  prepared.contract
}

pub fn prepared_decode(prepared: Prepared(o)) -> Decode(o) {
  prepared.decode
}

pub opaque type Stream(o) {
  Stream(
    source: owner.Stream,
    provider: message.Provider,
    decode: fn(String) -> Result(o, ValueFailure),
  )
}

pub fn stream(
  source: owner.Stream,
  provider: message.Provider,
  decode: fn(String) -> Result(o, ValueFailure),
) -> Stream(o) {
  Stream(source:, provider:, decode:)
}

pub fn source(stream: Stream(o)) -> owner.Stream {
  stream.source
}

pub fn provider(stream: Stream(o)) -> message.Provider {
  stream.provider
}

pub fn decode(stream: Stream(o), text: String) -> Result(o, ValueFailure) {
  stream.decode(text)
}
