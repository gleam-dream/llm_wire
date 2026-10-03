import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/config as http_config
import http_gun/deadline
import http_gun/error as http_error
import llm_wire/internal/api
import llm_wire/internal/owner
import llm_wire/provider
import llm_wire/types

type Control {
  More
  Stop
}

pub fn open(
  client: http_gun.Client,
  prepared: api.PreparedCall,
  limits: types.Limits,
  deadlines: types.Deadlines,
  checks: types.ToolCallChecks,
) -> Result(owner.Stream, types.WireError) {
  // Preparation is pure. This single absolute budget begins at execution.
  let budget = deadline.after(deadlines.overall_timeout_ms)
  use adapter <- result.try(api.prepared_adapter(prepared))
  let tools = api.prepared_tools(prepared)
  use reducer <- result.try(provider.new_reducer(adapter, limits, tools))
  owner.start_with_transport(
    provider.identity(adapter),
    reducer,
    limits,
    types.Deadlines(
      ..deadlines,
      overall_timeout_ms: deadline.remaining_ms(budget),
    ),
    fn(stream) { start(client, prepared, budget, stream, limits) },
    tools,
    checks,
    budget,
  )
}

fn start(
  client: http_gun.Client,
  prepared: api.PreparedCall,
  budget: deadline.Deadline,
  stream: owner.Stream,
  limits: types.Limits,
) -> owner.TransportPort {
  let ready = process.new_subject()
  // Created in the semantic owner: abnormal owner death terminates this worker.
  let worker =
    process.spawn(fn() {
      cancellation.with_token(fn(token) {
        let control = process.new_subject()
        process.send(ready, #(control, token))
        case process.receive(control, deadline.remaining_ms(budget)) {
          Ok(More) -> {
            // The call's budget replaces the client's request timeout, so a
            // shorter client default no longer cuts it. The semantic owner
            // runs the first-token and idle timers; the client's idle
            // timeout is lifted so it cannot cut them, and the budget still
            // bounds every wait.
            let call =
              client
              |> http_gun.with_deadline(budget)
              |> http_gun.with_idle_timeout(http_config.Infinity)
              |> http_gun.with_cancellation(token)
            let outcome =
              http_gun.with_response(
                call,
                api.http_request(prepared),
                fn(failure) { failure },
                fn(response) {
                  owner.request_was_sent(stream)
                  case response.status {
                    200 ->
                      case validate_headers(response.headers) {
                        Ok(Nil) -> read(response.body, control, stream, limits)
                        Error(error) ->
                          owner.feed_failure(
                            stream,
                            error,
                            types.RetryEvidence(
                              types.RequestMayHaveReachedProvider,
                              True,
                              False,
                            ),
                          )
                      }
                    status ->
                      error_body(
                        response.body,
                        response.headers,
                        status,
                        stream,
                        int.min(65_536, limits.response_body_bytes_limit),
                        [],
                        0,
                      )
                  }
                  Ok(Nil)
                },
              )
            case outcome {
              Ok(_) -> Nil
              Error(failure) -> fail(stream, failure, False)
            }
          }
          Ok(Stop) -> Nil
          Error(Nil) ->
            fail(
              stream,
              http_error.new(http_error.DeadlineExceeded, http_error.NotSent),
              False,
            )
        }
      })
    })
  case process.receive(ready, 1000) {
    Ok(#(control, token)) ->
      owner.TransportPort(
        request_more: fn() { process.send(control, More) },
        close: fn() {
          cancellation.cancel(token)
          process.send(control, Stop)
        },
      )
    Error(Nil) -> {
      process.kill(worker)
      owner.feed_failure(
        stream,
        types.ConfigurationError("HTTP worker startup failed"),
        types.initial_retry_evidence(),
      )
      owner.TransportPort(fn() { Nil }, fn() { Nil })
    }
  }
}

// The semantic owner controls its own idle and overall timers and cancels the
// token, which ends a blocked next, when one of them fires.
fn read(
  source: body.Body,
  control: process.Subject(Control),
  stream: owner.Stream,
  limits: types.Limits,
) -> Nil {
  case body.next(source) {
    Ok(body.Chunk(bytes)) ->
      case bit_array.byte_size(bytes) > limits.chunk_bytes_limit {
        True ->
          owner.feed_failure(
            stream,
            types.ResourceLimitExceeded(
              "chunk_bytes_limit",
              limits.chunk_bytes_limit,
              bit_array.byte_size(bytes),
            ),
            types.RetryEvidence(
              types.RequestMayHaveReachedProvider,
              True,
              False,
            ),
          )
        False -> {
          owner.feed_chunk(stream, bytes)
          case process.receive(control, 2_147_483_647) {
            Ok(More) -> read(source, control, stream, limits)
            Ok(Stop) | Error(Nil) -> Nil
          }
        }
      }
    Ok(body.End(_)) -> owner.feed_eof(stream)
    Error(failure) -> fail(stream, failure, False)
  }
}

fn error_body(
  source: body.Body,
  headers: List(#(String, String)),
  status: Int,
  stream: owner.Stream,
  limit: Int,
  chunks: List(BitArray),
  size: Int,
) -> Nil {
  case body.next(source) {
    Ok(body.End(_)) -> {
      let text =
        bit_array.concat(list.reverse(chunks))
        |> bit_array.to_string
        |> result.unwrap("Invalid UTF-8 error response")
      owner.feed_failure(
        stream,
        types.HttpStatusError(
          status,
          text,
          retry_hint(header(headers, "retry-after")),
        ),
        types.RetryEvidence(types.RequestMayHaveReachedProvider, True, False),
      )
    }
    Ok(body.Chunk(bytes)) -> {
      // Preserve the first independent observation before idle/deadline/close
      // can win while this finite status-body collection is still waiting.
      case size == 0 && bit_array.byte_size(bytes) > 0 {
        True -> owner.response_bytes_observed(stream)
        False -> Nil
      }
      case size + bit_array.byte_size(bytes) > limit {
        True ->
          owner.feed_failure(
            stream,
            types.ResourceLimitExceeded(
              "error_body_bytes_limit",
              limit,
              size + bit_array.byte_size(bytes),
            ),
            types.RetryEvidence(
              types.RequestMayHaveReachedProvider,
              True,
              False,
            ),
          )
        False ->
          error_body(
            source,
            headers,
            status,
            stream,
            limit,
            [bytes, ..chunks],
            size + bit_array.byte_size(bytes),
          )
      }
    }
    Error(failure) -> fail(stream, failure, size > 0)
  }
}

fn validate_headers(
  headers: List(#(String, String)),
) -> Result(Nil, types.WireError) {
  let media =
    header(headers, "content-type")
    |> string.split(";")
    |> list.first
    |> result.unwrap("")
    |> string.trim
    |> string.lowercase
  case media, header(headers, "content-encoding") |> string.lowercase {
    "text/event-stream", "" | "text/event-stream", "identity" -> Ok(Nil)
    "text/event-stream", _ ->
      Error(types.ProtocolError("Compressed responses are not accepted"))
    _, _ -> Error(types.ProtocolError("Response is not text/event-stream"))
  }
}

fn header(headers: List(#(String, String)), name: String) -> String {
  headers
  |> list.find(fn(h) { string.lowercase(h.0) == name })
  |> result.map(fn(h) { h.1 })
  |> result.unwrap("")
}

fn retry_hint(value: String) -> option.Option(types.RetryHint) {
  case value {
    "" -> None
    _ ->
      case int.parse(value) {
        Ok(seconds) if seconds >= 0 -> Some(types.RetryDelaySeconds(seconds))
        _ -> Some(types.RetryHeaderValue(value))
      }
  }
}

fn fail(stream: owner.Stream, failure: http_error.Failure, bytes: Bool) -> Nil {
  owner.feed_failure(
    stream,
    wire_error(failure),
    types.RetryEvidence(
      case http_error.evidence(failure) {
        http_error.NotSent -> types.NoRequestSent
        http_error.MaybeSent -> types.RequestMayHaveReachedProvider
      },
      bytes,
      False,
    ),
  )
}

pub fn wire_error(failure: http_error.Failure) -> types.WireError {
  case http_error.reason(failure) {
    http_error.DeadlineExceeded -> types.DeadlineExceeded(types.OverallDeadline)
    http_error.Cancelled -> types.CancelledLocally
    reason -> types.HttpFailure(reason)
  }
}
