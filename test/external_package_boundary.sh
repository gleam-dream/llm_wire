#!/bin/sh
set -eu

package_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM

make_consumer() {
  directory=$1
  mkdir -p "$directory/src"
  cat >"$directory/gleam.toml" <<EOF
name = "llm_wire_boundary_probe"
version = "0.1.0"
target = "erlang"
gleam = ">= 1.18.0"

[dependencies]
gleam_stdlib = ">= 0.70.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
gleam_http = ">= 4.4.0 and < 5.0.0"
gleam_time = ">= 1.11.0 and < 2.0.0"
json_blueprint = { path = "$package_root/../json_blueprint" }
llm_wire = { path = "$package_root" }
http_gun = { path = "$package_root/../http_gun" }
sinal = { path = "$package_root/../sinal" }
EOF
  # Use the actual consumer's pinned dependency closure, with absolute local
  # paths in the temporary package. All added direct imports already belong to
  # that closure. Keep versions pinned for every temporary consumer probe.
  python3 - "$package_root/examples/consumer/manifest.toml" "$directory" <<'PY'
import json
from pathlib import Path
import re
import sys
import tomllib

seed, destination = map(Path, sys.argv[1:])
packages = seed.read_text().split("[requirements]", 1)[0]
packages = re.sub(
    r'path = "([^"]+)"',
    lambda match: "path = " + json.dumps(str((seed.parent / match[1]).resolve())),
    packages,
)
dependencies = tomllib.loads((destination / "gleam.toml").read_text())["dependencies"]
requirements = []
for name, value in sorted(dependencies.items()):
    if isinstance(value, str):
        requirements.append(name + " = { version = " + json.dumps(value) + " }")
    else:
        requirements.append(name + " = { path = " + json.dumps(value["path"]) + " }")
(destination / "manifest.toml").write_text(packages + "[requirements]\n" + "\n".join(requirements) + "\n")
PY
}

positive="$scratch/positive"
make_consumer "$positive"
cp "$package_root/test/external_provider.gleam" "$positive/src/external_provider.gleam"

# The common path needs one LLM Wire import: the configuration arrives built.
cat >"$positive/src/common_path.gleam" <<'EOF'
import http_gun
import llm_wire

pub fn answer(
  client: http_gun.Client,
  config: llm_wire.Config,
  question: String,
) -> Result(String, String) {
  let request = llm_wire.request("consumer-model", [llm_wire.user(question)])
  case llm_wire.prepare(config, request) {
    Error(_) -> Error("not prepared")
    Ok(prepared) ->
      case llm_wire.run(client, prepared) {
        Ok(llm_wire.Answer(text:, ..)) -> Ok(text)
        Ok(_) -> Error("no final answer")
        Error(failure) -> Error(llm_wire.describe_failure(failure))
      }
  }
}
EOF

cat >"$positive/src/consumer.gleam" <<'EOF'
import common_path
import external_provider
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/duration.{type Duration}
import http_gun
import http_gun/config as http_config
import http_gun/testing as http_testing
import json/blueprint/codec
import json/blueprint/contract
import llm_wire
import llm_wire/error
import llm_wire/limit
import llm_wire/message
import llm_wire/openai
import llm_wire/provider
import llm_wire/telemetry
import llm_wire/testing
import llm_wire/tool
import sinal

pub fn openai_settings() -> llm_wire.Config {
  openai.new("consumer-key")
  |> openai.with_project("consumer-project")
  |> openai.config
  |> llm_wire.with_endpoint("https://api.example.test/v1")
  |> llm_wire.with_limit(limit.TotalTextBytes, 1_000_000)
  |> llm_wire.with_call_timeout(llm_wire.After(duration.seconds(30)))
  |> llm_wire.with_idle_timeout(llm_wire.Infinity)
}

pub fn ask(client: http_gun.Client) -> Result(String, String) {
  common_path.answer(client, openai_settings(), "hello")
}

fn query_codec() -> codec.Codec(String) {
  use query <- codec.field("query", codec.string(), get: fn(query) { query })
  codec.success(query)
}

fn answer_codec() -> codec.Codec(String) {
  use answer <- codec.field("answer", codec.string(), get: fn(answer) { answer })
  codec.success(answer)
}

pub fn prepares_schema_only_tools_and_structured_output() -> #(
  llm_wire.Prepared(String),
  llm_wire.Prepared(String),
) {
  let assert Ok(lookup_contract) = contract.from_codec(query_codec())
  let assert Ok(lookup) =
    tool.from_contract("lookup", "Lookup", lookup_contract)
  let assert Ok(search) =
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
      ]),
    )
  let request =
    llm_wire.request("consumer-model", [llm_wire.user("Find a result")])
    |> llm_wire.with_tools([lookup, search])
  let assert Ok(prepared) = llm_wire.prepare(openai_settings(), request)
  let assert Ok(structured) =
    llm_wire.prepare(
      openai_settings(),
      request |> llm_wire.with_output("answer", answer_codec()),
    )
  #(prepared, structured)
}

pub fn custom_adapter_config() -> Result(llm_wire.Prepared(String), error.PrepareError) {
  let config =
    external_provider.adapter("https://custom.example.test")
    |> provider.with_tool_schema(provider.blueprint_schema)
    |> provider.config
    |> llm_wire.with_tool_call_checks(tool.ReportInvalidToolCalls)
  llm_wire.prepare(config, llm_wire.request("m", [llm_wire.user("hello")]))
}

pub fn prepare_next_round(
  config: llm_wire.Config,
  source: llm_wire.Request(String),
  turn: message.AssistantTurn,
  results: List(#(message.ToolCall, String)),
) -> Result(llm_wire.Prepared(String), error.PrepareError) {
  let replies =
    list.map(results, fn(result) { llm_wire.tool_result(result.0, result.1) })
  llm_wire.prepare(
    config,
    llm_wire.append(source, [message.Assistant(turn), ..replies]),
  )
}

pub fn pending_work(outcome: llm_wire.Outcome(o)) -> List(message.ToolCall) {
  case outcome {
    llm_wire.NeedsTools(turn:, issues:, ..) -> {
      let _ = list.map(issues, tool.describe_issue)
      turn.calls
    }
    _ -> []
  }
}

pub fn retry_delay(failure: llm_wire.Failure) -> Option(Duration) {
  case llm_wire.advise(failure) {
    llm_wire.RetryAdvice(prospect: llm_wire.MayHelp, delay: llm_wire.ProviderDelay(wait)) ->
      Some(wait)
    llm_wire.RetryAdvice(prospect: llm_wire.MayHelp, delay: llm_wire.Backoff) ->
      Some(duration.seconds(1))
    llm_wire.RetryAdvice(prospect: llm_wire.WillNotHelpUnchanged, ..)
    | llm_wire.RetryAdvice(prospect: llm_wire.Unknown, ..) -> None
  }
}

pub fn scripts_a_provider_without_a_socket() -> Nil {
  let settings =
    testing.config() |> llm_wire.with_tool_call_checks(tool.ReportInvalidToolCalls)
  let request = llm_wire.request("consumer-model", [llm_wire.user("hello")])
  let assert Ok(prepared) = llm_wire.prepare(settings, request)
  let assert Ok(client) =
    http_testing.playback(
      http_testing.script([testing.exchange(prepared, testing.text("scripted"))]),
      http_config.default(),
    )
  let assert Ok(llm_wire.Answer(text: "scripted", ..)) =
    llm_wire.run(client, prepared)
  http_gun.stop(client)
}

pub fn lowers_a_reply_into_a_builtin_wire() -> testing.Reply {
  testing.text("hello")
  |> testing.with_usage(message.Usage(1, 2, 3))
  |> testing.events_for(message.OpenAI, _)
}

pub fn scripts_a_provider_failure(
  prepared: llm_wire.Prepared(o),
) -> #(http_testing.Exchange, llm_wire.Failure, Result(Nil, Nil)) {
  let limited =
    testing.exchange(prepared, testing.rate_limited(message.OpenAI))
    |> testing.with_retry_after(duration.seconds(2))
  let cut = testing.interrupted(testing.text("partial"))
  let served = testing.http_response(message.OpenAI, cut)
  let failure =
    testing.failure(message.OpenAI, error.Status(429, "slow", None))
  #(limited, failure, case served.status {
    200 -> Ok(Nil)
    _ -> Error(Nil)
  })
}

pub fn serves_a_reply_from_a_fake_server(
  reply: testing.Reply,
) -> #(Int, List(String), Bool) {
  let lowered = testing.events_for(message.Anthropic, reply)
  #(testing.status(lowered), testing.chunks(lowered), testing.is_interrupted(lowered))
}

pub fn builds_every_reply_without_a_constructor() -> List(testing.Reply) {
  [
    testing.tool_calls("", [
      testing.tool_call(id: "c1", name: "lookup", arguments_json: "{}"),
    ]),
    testing.content_filtered("partial"),
    testing.prompt_blocked(),
    testing.events(["event: delta\ndata: hi\n\n"]),
    testing.interrupted(testing.text("")),
    testing.http_status(message.Custom("scripted"), 501, "not implemented"),
  ]
}

pub fn content_filter_is_its_own_kind(failure: llm_wire.Failure) -> Bool {
  case error.kind(failure.error) {
    error.ContentPolicy -> True
    error.Transport
    | error.ProviderError
    | error.UnusableResponse
    | error.OverLimit
    | error.Ended -> False
  }
}

pub fn observe_with_sinal() -> sinal.Attachment {
  sinal.observe(telemetry.event(), fn(_, meta: telemetry.Metadata) {
    let _ = #(meta.call, meta.correlation, telemetry.stage_name(meta.stage))
    let _ = telemetry.outcome_name(meta.outcome)
    Nil
  })
}

pub fn stores_messages(history: List(message.Message)) -> String {
  json.to_string(json.array(history, message.to_json))
}

pub fn restores_messages(
  stored: String,
) -> Result(List(message.Message), json.DecodeError) {
  json.parse(stored, decode.list(message.decoder()))
}

pub fn stores_turns(turn: message.AssistantTurn) -> #(String, String) {
  #(
    json.to_string(message.turn_to_json(turn)),
    json.to_string(message.turn_replay_to_json(turn)),
  )
}

pub fn restores_turn(
  stored: String,
  text: String,
  calls: List(message.ToolCall),
) -> Result(message.AssistantTurn, json.DecodeError) {
  json.parse(stored, message.turn_replay_decoder(text, calls))
}
EOF
(cd "$positive" && gleam check --target erlang && gleam build --target erlang --warnings-as-errors)
(cd "$package_root/examples/consumer" && gleam build --warnings-as-errors && gleam run)

negative="$scratch/negative"
make_consumer "$negative"
# Gleam's supported build-tool API type-checks against the positive consumer's
# already compiled dependency closure. Expected failures never contact Hex.
compile_negative() {
  gleam compile-package --target erlang --no-beam \
    --package "$negative" --out "$negative/build" \
    --lib "$positive/build/dev/erlang"
}
cat >"$negative/src/consumer.gleam" <<'EOF'
import http_gun
import llm_wire
pub fn valid(client: http_gun.Client, call: llm_wire.Prepared(String)) {
  llm_wire.run(client, call)
}
EOF
compile_negative
# expect_rejected NAME CATEGORY SYMBOL [unknown-module-allowed]
expect_rejected() {
  name=$1
  category=$2
  symbol=$3
  module_allowed=${4:-}
  if compile_negative >"$scratch/$name.log" 2>&1; then
    printf '%s\n' "Forbidden consumer compiled: $name" >&2
    exit 1
  fi
  if ! rg -Fq "$category" "$scratch/$name.log" || ! rg -Fq "$symbol" "$scratch/$name.log"; then
    cat "$scratch/$name.log" >&2
    exit 1
  fi
  # A missing dependency or an unintended unknown module would also fail to
  # compile; only the removed-module cases may report an unknown module.
  if rg -q 'error:.*dependency' "$scratch/$name.log"; then
    cat "$scratch/$name.log" >&2
    exit 1
  fi
  if [ -z "$module_allowed" ] && rg -q '^error: Unknown module$' "$scratch/$name.log"; then
    cat "$scratch/$name.log" >&2
    exit 1
  fi
  printf '%s\n' "Rejected $name for $category ($symbol)"
}

for opaque in Prepared Request Config; do
  cat >"$negative/src/consumer.gleam" <<EOF
import llm_wire
pub fn fabricate() { llm_wire.$opaque("arbitrary") }
EOF
  expect_rejected "construct_$opaque" 'Unknown module value' \
    "llm_wire.$opaque is a type constructor"
done

cat >"$negative/src/consumer.gleam" <<'EOF'
import http_gun
import gleam/http/request
import llm_wire
pub fn bypass(client: http_gun.Client) {
  llm_wire.run(client, request.new() |> request.set_body(<<>>))
}
EOF
expect_rejected raw_http 'Type mismatch' 'Prepared'

cat >"$negative/src/consumer.gleam" <<'EOF'
import llm_wire
pub fn credentials(call: llm_wire.Prepared(String)) { call.call }
EOF
expect_rejected stored_credentials 'Unknown record field' 'call'

cat >"$negative/src/consumer.gleam" <<'EOF'
import llm_wire
pub fn config_adapter(config: llm_wire.Config) { config.adapter }
EOF
expect_rejected config_fields 'Unknown record field' 'adapter'

cat >"$negative/src/consumer.gleam" <<'EOF'
import llm_wire
pub fn structured() { llm_wire.prepare_structured }
EOF
expect_rejected prepare_structured 'Unknown module value' 'prepare_structured'

cat >"$negative/src/consumer.gleam" <<'EOF'
import llm_wire/testing
pub fn raw_reply() { testing.http_reply }
EOF
expect_rejected private_http_reply 'Unknown module value' 'http_reply'

for constructor in Events Interrupted Status ScriptedCall; do
  cat >"$negative/src/consumer.gleam" <<EOF
import llm_wire/testing
pub fn raw_reply() { testing.$constructor }
EOF
  expect_rejected "opaque_reply_$constructor" 'Unknown module value' "$constructor"
done

for removed in session config types retry; do
  cat >"$negative/src/consumer.gleam" <<EOF
import llm_wire/$removed
pub fn removed() { $removed.new }
EOF
  expect_rejected "removed_$removed" 'Unknown module' "llm_wire/$removed" allowed
done

printf '%s\n' 'Public wave 4 consumer works; opacity, raw-request, credential, and removed API boundaries hold.'
