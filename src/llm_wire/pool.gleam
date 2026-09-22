import gleam/erlang/process
import gleam/result
import llm_wire/types

pub type PoolConfig {
  PoolConfig(
    max_connections_per_target: Int,
    max_total_connections: Int,
    idle_timeout_ms: Int,
  )
}

pub fn default_pool_config() -> PoolConfig {
  PoolConfig(
    max_connections_per_target: 4,
    max_total_connections: 16,
    idle_timeout_ms: 30_000,
  )
}

pub opaque type Pool {
  Pool(pid: process.Pid)
}

pub type PoolInfo {
  PoolInfo(
    total_connections: Int,
    idle_connections: Int,
    leased_connections: Int,
    waiting_requests: Int,
  )
}

@external(erlang, "llm_wire_gun_pool", "start")
fn ffi_start_pool(
  max_per_target: Int,
  max_total: Int,
  idle_timeout_ms: Int,
) -> Result(process.Pid, String)

@external(erlang, "llm_wire_gun_pool", "stop")
fn ffi_stop_pool(pool_pid: process.Pid) -> Result(Nil, String)

@external(erlang, "llm_wire_gun_pool", "pool_info_tuple")
fn ffi_pool_info(pool_pid: process.Pid) -> #(Int, Int, Int, Int)

pub fn start(config: PoolConfig) -> Result(Pool, types.WireError) {
  case
    config.max_connections_per_target > 0
    && config.max_total_connections > 0
    && config.idle_timeout_ms >= 0
  {
    False ->
      Error(types.ConfigurationError(
        "Pool connection caps must be positive and idle timeout nonnegative",
      ))
    True ->
      ffi_start_pool(
        config.max_connections_per_target,
        config.max_total_connections,
        config.idle_timeout_ms,
      )
      |> result.map(Pool)
      |> result.map_error(fn(err) { types.ConfigurationError(err) })
  }
}

pub fn stop(pool: Pool) -> Result(Nil, types.WireError) {
  ffi_stop_pool(pool.pid)
  |> result.map_error(fn(reason) { types.TransportError(reason) })
}

pub fn info(pool: Pool) -> PoolInfo {
  let #(total, idle, leased, waiting) = ffi_pool_info(pool.pid)
  PoolInfo(
    total_connections: total,
    idle_connections: idle,
    leased_connections: leased,
    waiting_requests: waiting,
  )
}

pub fn pool_pid(pool: Pool) -> process.Pid {
  pool.pid
}
