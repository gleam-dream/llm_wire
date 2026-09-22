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
gleam_stdlib = ">= 0.70.0 and < 1.0.0"
llm_wire = { path = "$package_root" }
EOF
}

positive="$scratch/positive"
make_consumer "$positive"
cat >"$positive/src/consumer.gleam" <<'EOF'
import gleam/option.{None}
import llm_wire

pub fn prepares_through_the_root_facade() {
  let assert Ok(key) = llm_wire.api_key("consumer-key")
  let assert Ok(endpoint) = llm_wire.endpoint("https://api.example.test/v1")
  let assert Ok(model) = llm_wire.model_id("consumer-model")
  let config = llm_wire.openai_config(key, endpoint, None, None)
  let request = llm_wire.new_request(model, [llm_wire.UserMessage("hello")])
  llm_wire.prepare(config, request, llm_wire.default_limits())
}
EOF
(cd "$positive" && gleam check --target erlang)

negative="$scratch/negative"
make_consumer "$negative"
cat >"$negative/src/consumer.gleam" <<'EOF'
import gleam/erlang/process
import gleam/option.{None}
import llm_wire
import llm_wire/api
import llm_wire/internal/client
import llm_wire/internal/transport

pub fn prepared_call_cannot_be_fabricated() {
  api.PreparedCall("{\"arbitrary\":true}")
}

pub fn arbitrary_string_cannot_be_sent_as_a_prepared_call() {
  client.open_prepared_stream(
    "{\"arbitrary\":true}",
    llm_wire.default_limits(),
    llm_wire.default_deadlines(),
    None,
  )
}

pub fn old_raw_client_entry_is_absent() {
  client.open_openai_stream(
    "api.example.test",
    443,
    "/v1/responses",
    "consumer-key",
    llm_wire.default_limits(),
    llm_wire.default_deadlines(),
    [],
    "{\"arbitrary\":true}",
  )
}

pub fn raw_transport_fields_cannot_be_supplied() {
  transport.connect_and_stream(
    "api.example.test",
    443,
    "/v1/responses",
    [],
    "{\"arbitrary\":true}",
    1000,
    llm_wire.default_limits(),
    65536,
    process.self(),
    fn(_) { Nil },
    fn() { Nil },
    fn(_) { Nil },
    fn() { Nil },
  )
}

pub fn credential_headers_cannot_be_inspected() {
  let assert Ok(key) = llm_wire.api_key("consumer-key")
  let assert Ok(endpoint) = llm_wire.endpoint("https://api.example.test/v1")
  let assert Ok(model) = llm_wire.model_id("consumer-model")
  let config = llm_wire.openai_config(key, endpoint, None, None)
  let request = llm_wire.new_request(model, [llm_wire.UserMessage("hello")])
  let assert Ok(prepared) = llm_wire.prepare(config, request, llm_wire.default_limits())
  api.prepared_headers(prepared)
}
EOF

if (cd "$negative" && gleam check --target erlang) >"$scratch/negative.log" 2>&1; then
  cat "$scratch/negative.log"
  printf '%s\n' "The external raw-request probe unexpectedly compiled." >&2
  exit 1
fi

if ! rg -q 'PreparedCall' "$scratch/negative.log" \
  || ! rg -q 'open_openai_stream' "$scratch/negative.log" \
  || ! rg -q 'connect_and_stream' "$scratch/negative.log"; then
  cat "$scratch/negative.log" >&2
  printf '%s\n' "The external probe failed before reaching the raw-call type boundary." >&2
  exit 1
fi

if ! rg -q 'prepared_headers' "$scratch/negative.log"; then
  cat "$scratch/negative.log" >&2
  printf '%s\n' "The external probe did not enforce credential accessor privacy." >&2
  exit 1
fi

rg -n -A 3 -B 1 'error:' "$scratch/negative.log" || true
printf '%s\n' "External root-facade consumer compiled; raw-call consumer failed at the prepared-call boundary."
