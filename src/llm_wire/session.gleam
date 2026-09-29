import gleam/option.{type Option, None, Some}
import gleam/result
import json/blueprint/codec
import llm_wire/config
import llm_wire/internal/api
import llm_wire/internal/client
import llm_wire/internal/owner
import llm_wire/internal/stream_types
import llm_wire/internal/tls
import llm_wire/pool
import llm_wire/types

/// One admitted request with its transport and response settings.
pub opaque type PreparedCall {
  PreparedCall(call: api.PreparedCall, settings: config.Config)
}

pub type RunResult {
  RunText(text: String, usage: Option(types.Usage))
  RunToolCalls(turn: types.AssistantTurn, usage: Option(types.Usage))
  RunOutputLimited(
    partial_text: String,
    partial_calls: List(types.ToolCall),
    usage: Option(types.Usage),
  )
  RunRefusal(reason: String, usage: Option(types.Usage))
}

pub opaque type Stream {
  Stream(source: owner.Stream, prepared: PreparedCall)
}

pub type ReadError {
  StreamReadError(types.ReadError)
  TerminalConversionError(types.WireError)
}

pub type ReadResult {
  NextProgress(types.StreamProgress)
  StreamTerminal(Terminal)
}

pub type Terminal {
  Finished(RunResult)
  Failed(types.WireError, types.RetryEvidence)
  Cancelled(types.RetryEvidence)
}

/// Buffered execution preserves the same retry evidence exposed by streams.
/// Preparation errors remain WireError at the separate prepare step.
pub type RunFailure {
  RunFailure(error: types.WireError, retry: types.RetryEvidence)
}

pub fn prepare(
  settings: config.Config,
  request: types.Request,
) -> Result(PreparedCall, types.WireError) {
  use Nil <- result.try(config.validate(settings))
  use call <- result.try(api.prepare(
    config.adapter(settings),
    request,
    config.limits(settings),
  ))
  use Nil <- result.try(validate_ca_policy(call, settings))
  Ok(PreparedCall(call, settings))
}

fn ca_override(settings: config.Config) -> Option(tls.TlsMode) {
  case config.ca_cert_file(settings) {
    None -> None
    Some(path) -> Some(tls.VerifyCaFile(path))
  }
}

fn validate_ca_policy(
  call: api.PreparedCall,
  settings: config.Config,
) -> Result(Nil, types.WireError) {
  case ca_override(settings) {
    None -> Ok(Nil)
    Some(mode) -> api.validate_prepared_transport(call, mode)
  }
}

pub fn stream(prepared: PreparedCall) -> Result(Stream, RunFailure) {
  let PreparedCall(call, settings) = prepared
  open_source(call, settings)
  |> result.map(fn(source) { Stream(source, prepared) })
  |> result.map_error(open_failure)
}

fn open_source(
  call: api.PreparedCall,
  settings: config.Config,
) -> Result(owner.Stream, client.OpenFailure) {
  client.open_prepared_stream_with(
    call,
    config.limits(settings),
    config.deadlines(settings),
    ca_override(settings),
    option.map(config.pool(settings), pool.pool_pid),
    config.connector(settings),
    config.tool_call_checks(settings),
  )
}

pub fn run(prepared: PreparedCall) -> Result(RunResult, RunFailure) {
  use stream <- result.try(stream(prepared))
  collect(stream)
}

/// Collect one response from the owned stream.
pub fn collect(stream: Stream) -> Result(RunResult, RunFailure) {
  case next(stream) {
    Ok(NextProgress(_)) -> collect(stream)
    Ok(StreamTerminal(Finished(outcome))) -> Ok(outcome)
    Ok(StreamTerminal(Failed(error, retry))) -> Error(RunFailure(error, retry))
    Ok(StreamTerminal(Cancelled(retry))) ->
      Error(RunFailure(types.CancelledLocally, retry))
    Error(StreamReadError(types.ReadTimeout)) -> collect(stream)
    Error(error) -> Error(read_failure(error))
  }
}

fn open_failure(failure: client.OpenFailure) -> RunFailure {
  RunFailure(failure.error, failure.retry)
}

fn read_failure(error: ReadError) -> RunFailure {
  RunFailure(
    read_error_wire(error),
    types.RetryEvidence(types.EffectUnknown, True, True),
  )
}

fn read_error_wire(error: ReadError) -> types.WireError {
  case error {
    StreamReadError(types.StreamClosed) ->
      types.TransportError("Stream closed before a terminal result")
    StreamReadError(types.ConcurrentReadConflict) ->
      types.ConfigurationError(
        "Buffered runner lost exclusive stream ownership",
      )
    StreamReadError(types.OwnerUnavailable) ->
      types.TransportError("Stream owner unavailable")
    StreamReadError(types.ReadTimeout) ->
      types.DeadlineExceeded(types.ReadDeadline)
    TerminalConversionError(error) -> error
  }
}

fn wrap_result(outcome: api.RunResult) -> RunResult {
  case outcome {
    api.RunText(text, usage) -> RunText(text, usage)
    api.RunToolCalls(turn, usage) -> RunToolCalls(turn, usage)
    api.RunOutputLimited(text, calls, usage) ->
      RunOutputLimited(text, calls, usage)
    api.RunRefusal(reason, usage) -> RunRefusal(reason, usage)
  }
}

pub fn next(stream: Stream) -> Result(ReadResult, ReadError) {
  let Stream(source, prepared) = stream
  let PreparedCall(_, settings) = prepared
  case api.next(source, config.deadlines(settings).read_timeout_ms) {
    Error(error) -> Error(StreamReadError(error))
    Ok(stream_types.NextProgress(progress)) -> Ok(NextProgress(progress))
    Ok(stream_types.StreamTerminal(stream_types.StreamFailed(error, retry))) ->
      Ok(StreamTerminal(Failed(error, retry)))
    Ok(stream_types.StreamTerminal(stream_types.StreamCancelledLocally(retry))) ->
      Ok(StreamTerminal(Cancelled(retry)))
    Ok(stream_types.StreamTerminal(stream_types.StreamFinished(
      stream_types.Refused(reason),
      usage,
    ))) -> Ok(StreamTerminal(Finished(RunRefusal(reason, usage))))
    Ok(stream_types.StreamTerminal(terminal)) -> {
      let PreparedCall(call, _) = prepared
      case api.terminal_result(call, terminal) {
        Ok(outcome) -> Ok(StreamTerminal(Finished(wrap_result(outcome))))
        Error(error) -> Error(TerminalConversionError(error))
      }
    }
  }
}

pub fn close(stream: Stream) -> Result(types.CloseOutcome, types.ReadError) {
  api.close(stream.source)
}

pub fn prepared_provider(prepared: PreparedCall) -> types.Provider {
  api.prepared_provider(prepared.call)
}

pub fn prepared_request_json(prepared: PreparedCall) -> String {
  api.prepared_request_json(prepared.call)
}

/// The output codec applies to this prepared request.
pub opaque type PreparedStructuredCall(output) {
  PreparedStructuredCall(
    call: api.PreparedStructuredCall(output),
    settings: config.Config,
  )
}

pub type StructuredRunResult(output) {
  StructuredValue(value: output, raw_json: String, usage: Option(types.Usage))
  StructuredNeedsTools(turn: types.AssistantTurn, usage: Option(types.Usage))
  StructuredOutputLimited(
    partial_text: String,
    partial_calls: List(types.ToolCall),
    usage: Option(types.Usage),
  )
  StructuredRefusal(reason: String, usage: Option(types.Usage))
}

pub opaque type StructuredStream(output) {
  StructuredStream(
    source: owner.Stream,
    prepared: PreparedStructuredCall(output),
  )
}

pub type StructuredReadResult(output) {
  StructuredNextProgress(types.StreamProgress)
  StructuredStreamTerminal(StructuredTerminal(output))
}

pub type StructuredTerminal(output) {
  StructuredFinished(StructuredRunResult(output))
  StructuredFailed(types.WireError, types.RetryEvidence)
  StructuredCancelled(types.RetryEvidence)
}

pub fn prepare_structured(
  settings: config.Config,
  request: types.Request,
  output_name: String,
  output_codec: codec.Codec(output),
) -> Result(PreparedStructuredCall(output), types.WireError) {
  use Nil <- result.try(config.validate(settings))
  use call <- result.try(api.prepare_structured(
    config.adapter(settings),
    request,
    config.limits(settings),
    output_name,
    output_codec,
  ))
  use Nil <- result.try(validate_ca_policy(
    api.structured_prepared_call(call),
    settings,
  ))
  Ok(PreparedStructuredCall(call, settings))
}

pub fn stream_structured(
  prepared: PreparedStructuredCall(output),
) -> Result(StructuredStream(output), RunFailure) {
  let PreparedStructuredCall(call, settings) = prepared
  let api_call = api.structured_prepared_call(call)
  open_source(api_call, settings)
  |> result.map(fn(source) { StructuredStream(source, prepared) })
  |> result.map_error(open_failure)
}

pub fn run_structured(
  prepared: PreparedStructuredCall(output),
) -> Result(StructuredRunResult(output), RunFailure) {
  use stream <- result.try(stream_structured(prepared))
  collect_structured(stream)
}

pub fn collect_structured(
  stream: StructuredStream(output),
) -> Result(StructuredRunResult(output), RunFailure) {
  case next_structured(stream) {
    Ok(StructuredNextProgress(_)) -> collect_structured(stream)
    Ok(StructuredStreamTerminal(StructuredFinished(outcome))) -> Ok(outcome)
    Ok(StructuredStreamTerminal(StructuredFailed(error, retry))) ->
      Error(RunFailure(error, retry))
    Ok(StructuredStreamTerminal(StructuredCancelled(retry))) ->
      Error(RunFailure(types.CancelledLocally, retry))
    Error(StreamReadError(types.ReadTimeout)) -> collect_structured(stream)
    Error(error) -> Error(read_failure(error))
  }
}

fn wrap_structured_result(
  prepared: PreparedStructuredCall(output),
  outcome: api.RunResult,
) -> Result(StructuredRunResult(output), types.WireError) {
  let PreparedStructuredCall(call, _) = prepared
  case outcome {
    api.RunText(text, usage) -> {
      use value <- result.try(api.decode_structured_output(call, text))
      Ok(StructuredValue(value, text, usage))
    }
    api.RunToolCalls(turn, usage) -> Ok(StructuredNeedsTools(turn, usage))
    api.RunOutputLimited(text, calls, usage) ->
      Ok(StructuredOutputLimited(text, calls, usage))
    api.RunRefusal(reason, usage) -> Ok(StructuredRefusal(reason, usage))
  }
}

pub fn next_structured(
  stream: StructuredStream(output),
) -> Result(StructuredReadResult(output), ReadError) {
  let StructuredStream(source, prepared) = stream
  let PreparedStructuredCall(_, settings) = prepared
  case api.next(source, config.deadlines(settings).read_timeout_ms) {
    Error(error) -> Error(StreamReadError(error))
    Ok(stream_types.NextProgress(progress)) ->
      Ok(StructuredNextProgress(progress))
    Ok(stream_types.StreamTerminal(stream_types.StreamFailed(error, retry))) ->
      Ok(StructuredStreamTerminal(StructuredFailed(error, retry)))
    Ok(stream_types.StreamTerminal(stream_types.StreamCancelledLocally(retry))) ->
      Ok(StructuredStreamTerminal(StructuredCancelled(retry)))
    Ok(stream_types.StreamTerminal(stream_types.StreamFinished(
      stream_types.Refused(reason),
      usage,
    ))) ->
      Ok(
        StructuredStreamTerminal(
          StructuredFinished(StructuredRefusal(reason, usage)),
        ),
      )
    Ok(stream_types.StreamTerminal(terminal)) -> {
      let PreparedStructuredCall(call, _) = prepared
      let api_call = api.structured_prepared_call(call)
      case api.terminal_result(api_call, terminal) {
        Error(error) -> Error(TerminalConversionError(error))
        Ok(outcome) ->
          case wrap_structured_result(prepared, outcome) {
            Error(error) -> Error(TerminalConversionError(error))
            Ok(result) ->
              Ok(StructuredStreamTerminal(StructuredFinished(result)))
          }
      }
    }
  }
}

pub fn close_structured(
  stream: StructuredStream(output),
) -> Result(types.CloseOutcome, types.ReadError) {
  api.close(stream.source)
}

pub fn structured_request_json(
  prepared: PreparedStructuredCall(output),
) -> String {
  api.structured_request_json(prepared.call)
}
