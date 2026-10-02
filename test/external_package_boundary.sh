#!/bin/sh
set -eu

package_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
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
cat >"$positive/src/consumer.gleam" <<'EOF'
import external_provider
import http_gun
import http_gun/config as http_config
import http_gun/testing as http_testing
import gleam/list
import json/blueprint/codec
import json/blueprint/contract
import llm_wire/config
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/retry
import llm_wire/telemetry
import llm_wire/testing
import llm_wire/types
import sinal

pub fn prepares_through_configured_session() {
  let assert Ok(key) = types.api_key("consumer-key")
  let assert Ok(endpoint) = types.endpoint("https://api.example.test/v1")
  let assert Ok(model) = types.model_id("consumer-model")
  let settings =
    config.openai(openai.options(key)) |> config.with_endpoint(endpoint)
  let request = types.new_request(model, [types.UserMessage("hello")])
  let assert Ok(prepared) = session.prepare(settings, request)
  let custom = config.from_provider(external_provider.adapter(endpoint))
  let assert Ok(_) = session.prepare(custom, request)
  prepared
}

pub fn prepares_schema_only_tool_and_structured_output() {
  let assert Ok(key) = types.api_key("consumer-key")
  let assert Ok(model) = types.model_id("consumer-model")
  let assert Ok(name) = types.tool_name("lookup")
  let assert Ok(lookup_contract) = contract.from_codec(query_codec())
  let tool = types.tool_from_contract(name, "Lookup", lookup_contract)
  let request =
    types.new_request(model, [types.UserMessage("Find a result")])
    |> types.with_tools([tool])
  let settings = config.openai(openai.options(key))
  let assert Ok(prepared) = session.prepare(settings, request)
  let assert Ok(structured) =
    session.prepare_structured(
      settings,
      request,
      "answer",
      answer_codec(),
    )
  #(prepared, structured)
}

fn query_codec() -> codec.Codec(String) {
  use query <- codec.field("query", codec.string(), fn(query) { query })
  codec.success(query)
}

fn answer_codec() -> codec.Codec(String) {
  use answer <- codec.field("answer", codec.string(), fn(answer) { answer })
  codec.success(answer)
}

pub fn prepare_next_round(
  settings: config.Config,
  source: types.Request,
  turn: types.AssistantTurn,
  results: List(types.ToolResult),
) -> Result(session.PreparedCall, types.WireError) {
  let messages = list.append(source.messages, [
    types.AssistantTurnMessage(turn),
    ..list.map(results, fn(result) {
      types.ToolResultMessage(result.call_id, result.content)
    })
  ])
  session.prepare(settings, types.Request(..source, messages: messages))
}

pub fn pending_work(turn: types.AssistantTurn) -> List(types.ToolCall) {
  turn.calls
}

pub fn assesses_failure(provider: types.Provider, error: types.WireError) {
  retry.assess(provider, error)
}

pub fn scripts_a_provider_without_a_socket() {
  let assert Ok(model) = types.model_id("consumer-model")
  let request = types.new_request(model, [types.UserMessage("hello")])
  let settings = testing.config() |> config.with_tool_call_checks(types.ReportInvalidToolCalls)
  let assert Ok(prepared) = session.prepare(settings, request)
  let assert Ok(client) = http_testing.start(http_config.default(), [testing.exchange(prepared, testing.text("scripted"))])
  let assert Ok(session.RunText("scripted", _)) = session.run(client, prepared)
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}

pub fn observe_with_sinal() -> sinal.Attachment {
  sinal.observe(telemetry.observation_event(), fn(_, _metadata) { Nil })
}
EOF
(cd "$positive" && gleam check --target erlang)
(cd "$package_root/examples/consumer" && gleam run)

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
import llm_wire/session
pub fn valid(client: http_gun.Client, call: session.PreparedCall) {
  session.run(client, call)
}
EOF
compile_negative
expect_rejected() {
  name=$1
  category=$2
  symbol=$3
  if compile_negative >"$scratch/$name.log" 2>&1; then
    printf '%s\n' "Forbidden consumer compiled: $name" >&2
    exit 1
  fi
  if ! rg -Fq "$category" "$scratch/$name.log" || ! rg -Fq "$symbol" "$scratch/$name.log"; then
    cat "$scratch/$name.log" >&2
    exit 1
  fi
  if rg -q '^error: Unknown module$|error:.*dependency' "$scratch/$name.log"; then
    cat "$scratch/$name.log" >&2
    exit 1
  fi
  printf '%s\n' "Rejected $name for $category ($symbol)"
}

cat >"$negative/src/consumer.gleam" <<'EOF'
import llm_wire/session
pub fn fabricate() { session.PreparedCall("arbitrary") }
EOF
expect_rejected opaque 'Unknown module value' 'PreparedCall'

cat >"$negative/src/consumer.gleam" <<'EOF'
import http_gun
import gleam/http/request
import llm_wire/session
pub fn bypass(client: http_gun.Client) {
  session.run(client, request.new() |> request.set_body(<<>>))
}
EOF
expect_rejected raw_http 'Type mismatch' 'PreparedCall'

cat >"$negative/src/consumer.gleam" <<'EOF'
import llm_wire/session
pub fn credentials(call: session.PreparedCall) { call.call }
EOF
expect_rejected stored_credentials 'Unknown record field' 'PreparedCall'

cat >"$negative/src/consumer.gleam" <<'EOF'
import llm_wire/session
pub fn continuation() { session.prepare_continue }
EOF
expect_rejected continuation 'Unknown module value' 'prepare_continue'

cat >"$negative/src/consumer.gleam" <<'EOF'
import llm_wire/session
pub fn checkpoint() { session.export_continuation }
EOF
expect_rejected checkpoint 'Unknown module value' 'export_continuation'

cat >"$negative/src/consumer.gleam" <<'EOF'
import llm_wire/config
pub fn obsolete_pool() { config.with_pool }
EOF
expect_rejected obsolete_pool 'Unknown module value' 'with_pool'

printf '%s\n' 'Public migrated consumer works; opacity, raw-request, credential, and removed API boundaries hold.'
