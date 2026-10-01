//// Internal prepared-call runner for provider-focused regression consumers.

import gleam/result
import http_gun
import llm_wire/internal/api
import llm_wire/internal/http_client
import llm_wire/internal/owner
import llm_wire/types

pub fn stream(
  client: http_gun.Client,
  prepared: api.PreparedCall,
  limits: types.Limits,
  deadlines: types.Deadlines,
) -> Result(owner.Stream, types.WireError) {
  http_client.open(
    client,
    prepared,
    limits,
    deadlines,
    types.RejectInvalidToolCalls,
  )
}

pub fn run(
  client: http_gun.Client,
  prepared: api.PreparedCall,
  limits: types.Limits,
  deadlines: types.Deadlines,
) -> Result(api.RunResult, types.WireError) {
  use stream <- result.try(stream(client, prepared, limits, deadlines))
  api.collect_run(stream, prepared, deadlines.read_timeout_ms)
}
