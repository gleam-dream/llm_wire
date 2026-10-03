//// Declares the tools a model may call and checks the calls it makes.
////
//// Declare a tool from a Blueprint codec written in your code, or from a
//// JSON Schema received at runtime, such as an MCP `inputSchema`:
////
//// ```gleam
//// import llm_wire
//// import llm_wire/tool
////
//// let weather = tool.new("get_weather", "Current weather", weather_codec)
//// let request =
////   llm_wire.request("gpt-5", [llm_wire.user("Weather in Paris?")])
////   |> llm_wire.with_tools([weather])
//// ```
////
//// `new` is for definitions in source code and panics, naming the tool, on
//// a definition bug such as an invalid name or a codec without a schema.
//// `from_contract` and `from_json_schema` take runtime data and return a
//// typed `ToolError` instead.
////
//// A returned call is admitted against its declaration before the caller
//// sees it. By default an unknown tool or invalid arguments fail the
//// response; with `llm_wire.with_tool_call_checks(config,
//// ReportInvalidToolCalls)` every call is returned and each failing one is
//// listed as a `ToolCallIssue` in `llm_wire.NeedsTools`. Answer such a call
//// with `describe_issue(issue)` as its result. `decode_arguments` turns a
//// call's arguments into your value.

import gleam/json
import gleam/result
import json/blueprint/codec
import json/blueprint/contract
import json/blueprint/value
import llm_wire/error.{type ValueFailure}
import llm_wire/internal/tool_def
import llm_wire/message.{type ToolCall}

/// A tool declaration: a name, a description and an input schema.
pub type Tool =
  tool_def.Tool

/// Why a tool name falls outside `^[a-zA-Z0-9_-]{1,64}$`, the rule every
/// built-in provider accepts.
pub type NameProblem {
  EmptyName
  /// The first character outside ASCII letters, digits, `_` and `-`.
  InvalidCharacter(character: String)
  /// The name has more than 64 characters.
  NameTooLong(length: Int)
}

/// Why a runtime tool declaration was refused.
pub type ToolError {
  InvalidName(name: String, problem: NameProblem)
  /// The JSON Schema document is not valid JSON or uses keywords outside
  /// Blueprint's profile.
  InvalidSchema(contract.LoadError)
}

/// Why one returned call cannot be dispatched as declared.
pub type ToolCallIssue {
  /// The call names a tool the request did not declare.
  UnknownTool(call_id: String)
  /// The arguments are not JSON, fail the schema, or fail native decoding.
  InvalidArguments(call_id: String, failure: ValueFailure)
}

/// How a response treats a call to an unknown tool or with invalid
/// arguments.
pub type ToolCallChecks {
  /// Fail the response with `error.Protocol`. The default.
  RejectInvalidToolCalls
  /// Return every call and list each failing one as a `ToolCallIssue`.
  ReportInvalidToolCalls
}

/// Declare a tool whose input is `input`. Panics, naming the tool, when the
/// name is outside the tool-name rule or the codec has no usable schema;
/// both are bugs in source code.
pub fn new(name: String, description: String, input: codec.Codec(a)) -> Tool {
  case check_name(name) {
    Error(problem) ->
      panic as {
        "llm_wire/tool.new: invalid tool name \""
        <> name
        <> "\": "
        <> describe_name_problem(problem)
      }
    Ok(Nil) -> Nil
  }
  let schema = case codec.schema(input) {
    Ok(schema) -> schema
    Error(_) ->
      panic as {
        "llm_wire/tool.new: the input codec of tool \""
        <> name
        <> "\" has no schema"
      }
  }
  let input_contract = case contract.from_schema(schema) {
    Ok(admitted) -> admitted
    Error(problem) ->
      panic as {
        "llm_wire/tool.new: the input schema of tool \""
        <> name
        <> "\" is invalid: "
        <> codec.describe_definition_error(problem)
      }
  }
  tool_def.new(name, description, schema, input_contract, fn(validated) {
    contract.decode(input, validated) |> result.replace(Nil)
  })
}

/// Declare a schema-only tool from a contract built at runtime.
pub fn from_contract(
  name: String,
  description: String,
  input: contract.Contract,
) -> Result(Tool, ToolError) {
  use Nil <- result.try(
    check_name(name) |> result.map_error(InvalidName(name, _)),
  )
  Ok(
    tool_def.new(name, description, contract.schema(input), input, fn(_) {
      Ok(Nil)
    }),
  )
}

/// Declare a schema-only tool from a JSON Schema document, such as an MCP
/// tool's `inputSchema`. A document without `$schema` is read as Draft
/// 2020-12.
pub fn from_json_schema(
  name: String,
  description: String,
  schema: json.Json,
) -> Result(Tool, ToolError) {
  use Nil <- result.try(
    check_name(name) |> result.map_error(InvalidName(name, _)),
  )
  let text = json.to_string(schema)
  use document <- result.try(
    value.parse(text, value.default_limits())
    |> result.map_error(fn(problem) {
      InvalidSchema(contract.InvalidJson(problem))
    }),
  )
  let document = case document {
    value.Object(members) ->
      case has_member(members, "$schema") {
        True -> document
        False ->
          value.Object([
            #(
              "$schema",
              value.String("https://json-schema.org/draft/2020-12/schema"),
            ),
            ..members
          ])
      }
    other -> other
  }
  use input <- result.try(
    contract.load(document)
    |> result.map_error(fn(problem) {
      InvalidSchema(contract.InvalidDocument(problem))
    }),
  )
  from_contract(name, description, input)
}

fn has_member(members: List(#(String, value.Value)), key: String) -> Bool {
  case members {
    [] -> False
    [#(found, _), ..rest] -> found == key || has_member(rest, key)
  }
}

pub fn name(tool: Tool) -> String {
  tool_def.name(tool)
}

pub fn description(tool: Tool) -> String {
  tool_def.description(tool)
}

/// The tool's input schema, as providers receive it before projection.
pub fn schema(tool: Tool) -> codec.Schema {
  tool_def.schema(tool)
}

/// Decode a call's arguments with `input`, validating them against the
/// codec's schema. Parsing is bounded by Blueprint's default limits (1 MiB,
/// depth 64).
pub fn decode_arguments(
  call: ToolCall,
  input: codec.Codec(a),
) -> Result(a, ValueFailure) {
  let bounds = value.default_limits()
  use parsed <- result.try(
    value.parse(call.arguments_json, bounds)
    |> result.map_error(error.InvalidJson),
  )
  case codec.schema(input) |> result.map(contract.from_schema) {
    Ok(Ok(input_contract)) ->
      case contract.validate(input_contract, parsed) {
        Error(problem) -> Error(error.SchemaRejected(problem))
        Ok(validated) ->
          contract.decode(input, validated)
          |> result.map_error(error.DecodeRejected)
      }
    // A codec without a schema decodes directly.
    _ -> codec.decode(input, parsed) |> result.map_error(error.DecodeRejected)
  }
}

/// Check a name against the tool-name rule every built-in provider
/// accepts.
pub fn check_name(name: String) -> Result(Nil, NameProblem) {
  case tool_def.check_name(name) {
    Ok(Nil) -> Ok(Nil)
    Error(tool_def.NameEmpty) -> Error(EmptyName)
    Error(tool_def.NameCharacter(character)) ->
      Error(InvalidCharacter(character))
    Error(tool_def.NameLength(length)) -> Error(NameTooLong(length))
  }
}

/// Text for the tool result that answers a failing call, for the model to
/// read.
pub fn describe_issue(issue: ToolCallIssue) -> String {
  case issue {
    UnknownTool(_) -> "Unknown tool"
    InvalidArguments(_, failure) ->
      "Invalid arguments: " <> error.describe_value_failure(failure)
  }
}

pub fn describe_error(error: ToolError) -> String {
  case error {
    InvalidName(name, problem) ->
      "Invalid tool name \"" <> name <> "\": " <> describe_name_problem(problem)
    InvalidSchema(problem) ->
      "Invalid tool schema: " <> contract.describe_load_error(problem)
  }
}

fn describe_name_problem(problem: NameProblem) -> String {
  case problem {
    EmptyName -> "the name is empty"
    InvalidCharacter(character) ->
      "\"" <> character <> "\" is not a letter, digit, _ or -"
    NameTooLong(_) -> "the name is longer than 64 characters"
  }
}
