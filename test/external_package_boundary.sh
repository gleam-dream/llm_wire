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
import llm_wire/config
import llm_wire/session
import llm_wire/types

pub fn prepares_through_configured_session() {
  let assert Ok(key) = types.api_key("consumer-key")
  let assert Ok(endpoint) = types.endpoint("https://api.example.test/v1")
  let assert Ok(model) = types.model_id("consumer-model")
  let settings = config.openai(key) |> config.with_endpoint(endpoint)
  let request = types.new_request(model, [types.UserMessage("hello")])
  session.prepare(settings, request)
}
EOF
(cd "$positive" && gleam check --target erlang)

negative="$scratch/negative"
make_consumer "$negative"
cat >"$negative/src/consumer.gleam" <<'EOF'
import gleam/erlang/process
import gleam/option.{None}
import llm_wire/internal/api
import llm_wire/internal/client
import llm_wire/internal/transport
import llm_wire/types

pub fn prepared_call_cannot_be_fabricated() {
  api.PreparedCall("{\"arbitrary\":true}")
}

pub fn arbitrary_string_cannot_be_sent_as_a_prepared_call() {
  client.open_prepared_stream(
    "{\"arbitrary\":true}",
    types.default_limits(),
    types.default_deadlines(),
    None,
  )
}

pub fn old_raw_client_entry_is_absent() {
  client.open_openai_stream(
    "api.example.test",
    443,
    "/v1/responses",
    "consumer-key",
    types.default_limits(),
    types.default_deadlines(),
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
    types.default_limits(),
    65536,
    process.self(),
    fn(_) { Nil },
    fn() { Nil },
    fn(_) { Nil },
    fn() { Nil },
  )
}

pub fn credential_headers_cannot_be_inspected() {
  api.prepared_headers
}
EOF

if (cd "$negative" && gleam check --target erlang) >"$scratch/negative.log" 2>&1; then
  cat "$scratch/negative.log"
  printf '%s\n' "The external raw-request probe unexpectedly compiled." >&2
  exit 1
fi

if ! rg -q 'PreparedCall' "$scratch/negative.log" \
  || ! rg -q 'open_openai_stream' "$scratch/negative.log" \
  || ! rg -q 'connect_and_stream' "$scratch/negative.log" \
  || ! rg -q 'prepared_headers' "$scratch/negative.log"; then
  cat "$scratch/negative.log" >&2
  printf '%s\n' "The external probe failed before reaching every raw-call boundary." >&2
  exit 1
fi

rg -n -A 3 -B 1 'error:' "$scratch/negative.log" || true
printf '%s\n' "Configured consumer compiled; raw-call consumer failed at the prepared-call boundary."
