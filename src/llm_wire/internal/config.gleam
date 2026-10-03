import gleam/int
import gleam/option.{type Option, Some}
import llm_wire/error
import llm_wire/internal/adapter.{type Adapter}
import llm_wire/internal/limits.{type Limits}
import llm_wire/tool

/// The three timers of a call, in whole milliseconds. `None` is unbounded.
pub type Timeouts {
  Timeouts(
    whole_call: Option(Int),
    first_token: Option(Int),
    idle_gap: Option(Int),
  )
}

pub fn default_timeouts() -> Timeouts {
  Timeouts(
    whole_call: Some(600_000),
    first_token: Some(180_000),
    idle_gap: Some(60_000),
  )
}

/// Pure provider and execution settings. HTTP policy and client lifetime
/// belong to the application's HTTP Gun client.
pub opaque type Config {
  Config(
    adapter: Adapter,
    limits: Limits,
    timeouts: Timeouts,
    checks: tool.ToolCallChecks,
  )
}

pub fn new(adapter: Adapter) -> Config {
  Config(
    adapter:,
    limits: limits.default(),
    timeouts: default_timeouts(),
    checks: tool.RejectInvalidToolCalls,
  )
}

pub fn validate_timeouts(
  timeouts: Timeouts,
) -> Result(Nil, error.PrepareError) {
  let check = fn(value, timeout) {
    case value {
      Some(ms) if ms <= 0 ->
        Error(error.InvalidSetting(
          error.TimeoutSetting(timeout),
          "must be positive, got " <> int.to_string(ms) <> " ms",
        ))
      _ -> Ok(Nil)
    }
  }
  case check(timeouts.whole_call, error.WholeCall) {
    Error(problem) -> Error(problem)
    Ok(Nil) ->
      case check(timeouts.first_token, error.FirstToken) {
        Error(problem) -> Error(problem)
        Ok(Nil) -> check(timeouts.idle_gap, error.IdleGap)
      }
  }
}

pub fn adapter(config: Config) -> Adapter {
  config.adapter
}

pub fn limits(config: Config) -> Limits {
  config.limits
}

pub fn timeouts(config: Config) -> Timeouts {
  config.timeouts
}

pub fn checks(config: Config) -> tool.ToolCallChecks {
  config.checks
}

pub fn with_adapter(config: Config, adapter: Adapter) -> Config {
  Config(..config, adapter:)
}

pub fn with_limits(config: Config, limits: Limits) -> Config {
  Config(..config, limits:)
}

pub fn with_timeouts(config: Config, timeouts: Timeouts) -> Config {
  Config(..config, timeouts:)
}

pub fn with_checks(config: Config, checks: tool.ToolCallChecks) -> Config {
  Config(..config, checks:)
}
