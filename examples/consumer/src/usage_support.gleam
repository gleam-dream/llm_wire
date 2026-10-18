//// Offline plumbing shared by the usage examples: a scripted HTTP Gun client
//// and request preparation. Nothing here contacts a provider.

import http_gun
import http_gun/config as http_config
import http_gun/testing as http_testing
import llm_wire

/// Run `run` with an HTTP Gun client that answers from `exchanges`, then stop
/// the client. The scripted client is the stand-in for the application's real,
/// caller-owned client.
pub fn scripted(
  exchanges: List(http_testing.Exchange),
  run: fn(http_gun.Client) -> a,
) -> a {
  let assert Ok(client) =
    http_testing.playback(http_testing.script(exchanges), http_config.default())
  let result = run(client)
  http_gun.stop(client)
  result
}

/// Validate and encode `request` for `config`, panicking on a setup error.
pub fn prepared(
  config: llm_wire.Config,
  request: llm_wire.Request(o),
) -> llm_wire.Prepared(o) {
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  prepared
}
