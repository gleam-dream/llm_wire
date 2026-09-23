import gleam/option.{None, Some}
import gleam/result
import llm_wire/internal/api
import llm_wire/internal/client
import llm_wire/internal/owner
import llm_wire/pool
import llm_wire/types

pub fn stream(
  prepared: api.PreparedCall,
  limits: types.Limits,
  deadlines: types.Deadlines,
) -> Result(owner.Stream, types.WireError) {
  client.open_prepared_stream(prepared, limits, deadlines, None)
  |> result.map_error(fn(failure) { failure.error })
}

pub fn stream_with_pool(
  pool: pool.Pool,
  prepared: api.PreparedCall,
  limits: types.Limits,
  deadlines: types.Deadlines,
) -> Result(owner.Stream, types.WireError) {
  client.open_prepared_stream_with_pool(
    prepared,
    limits,
    deadlines,
    None,
    Some(pool.pool_pid(pool)),
  )
  |> result.map_error(fn(failure) { failure.error })
}

pub fn run(
  prepared: api.PreparedCall,
  limits: types.Limits,
  deadlines: types.Deadlines,
) -> Result(api.RunResult, types.WireError) {
  use stream <- result.try(stream(prepared, limits, deadlines))
  api.collect_run(stream, prepared, deadlines.read_timeout_ms)
}

pub fn run_with_pool(
  pool: pool.Pool,
  prepared: api.PreparedCall,
  limits: types.Limits,
  deadlines: types.Deadlines,
) -> Result(api.RunResult, types.WireError) {
  use stream <- result.try(stream_with_pool(pool, prepared, limits, deadlines))
  api.collect_run(stream, prepared, deadlines.read_timeout_ms)
}

pub fn stream_structured(
  prepared: api.PreparedStructuredCall(output),
  limits: types.Limits,
  deadlines: types.Deadlines,
) -> Result(owner.Stream, types.WireError) {
  stream(api.structured_prepared_call(prepared), limits, deadlines)
}

pub fn stream_structured_with_pool(
  pool: pool.Pool,
  prepared: api.PreparedStructuredCall(output),
  limits: types.Limits,
  deadlines: types.Deadlines,
) -> Result(owner.Stream, types.WireError) {
  stream_with_pool(
    pool,
    api.structured_prepared_call(prepared),
    limits,
    deadlines,
  )
}

pub fn run_structured(
  prepared: api.PreparedStructuredCall(output),
  limits: types.Limits,
  deadlines: types.Deadlines,
) -> Result(api.StructuredRunResult(output), types.WireError) {
  use run_result <- result.try(run(
    api.structured_prepared_call(prepared),
    limits,
    deadlines,
  ))
  case run_result {
    api.RunText(text, usage) -> {
      use output <- result.try(api.decode_structured_output(prepared, text))
      Ok(api.StructuredValue(output, text, usage))
    }
    api.RunToolCalls(_, calls, continuation, usage) ->
      Ok(api.StructuredNeedsTools(calls, continuation, usage))
    api.RunOutputLimited(text, calls, usage) ->
      Ok(api.StructuredOutputLimited(text, calls, usage))
    api.RunRefusal(reason, _) -> Ok(api.StructuredRefusal(reason))
  }
}

pub fn run_structured_with_pool(
  pool: pool.Pool,
  prepared: api.PreparedStructuredCall(output),
  limits: types.Limits,
  deadlines: types.Deadlines,
) -> Result(api.StructuredRunResult(output), types.WireError) {
  use run_result <- result.try(run_with_pool(
    pool,
    api.structured_prepared_call(prepared),
    limits,
    deadlines,
  ))
  case run_result {
    api.RunText(text, usage) -> {
      use output <- result.try(api.decode_structured_output(prepared, text))
      Ok(api.StructuredValue(output, text, usage))
    }
    api.RunToolCalls(_, calls, continuation, usage) ->
      Ok(api.StructuredNeedsTools(calls, continuation, usage))
    api.RunOutputLimited(text, calls, usage) ->
      Ok(api.StructuredOutputLimited(text, calls, usage))
    api.RunRefusal(reason, _) -> Ok(api.StructuredRefusal(reason))
  }
}
