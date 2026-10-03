//// Runs one prepared call over the application's HTTP Gun client and feeds
//// its response into the call's owner.

import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/config as http_config
import http_gun/deadline
import http_gun/destination
import http_gun/error as http_error
import llm_wire/error
import llm_wire/internal/adapter
import llm_wire/internal/api
import llm_wire/internal/owner
import llm_wire/internal/retry_after
import llm_wire/internal/stream_types
import llm_wire/limit

type Control {
  More
  Stop
}

/// Opens the call. The call's whole-call budget replaces the client's
/// request timeout, so a shorter client default never cuts it; the client's
/// idle timeout is lifted because the owner runs the first-token and
/// idle-gap timers. A plaintext endpoint is narrowed to loopback addresses
/// by HTTP Gun's destination policy, so credentials never cross a network
/// in clear text.
pub fn open(
  client: http_gun.Client,
  prepared: api.PreparedCall,
  setup: owner.Setup,
) -> Result(owner.Stream, Nil) {
  let budget =
    option.map(setup.timeouts.whole_call, fn(ms) {
      deadline.after(duration.milliseconds(ms))
    })
  let client = case budget {
    Some(budget) -> http_gun.with_deadline(client, budget)
    None -> http_gun.with_timeout(client, http_config.Infinity)
  }
  let client =
    client
    |> http_gun.with_idle_timeout(http_config.Infinity)
    |> plaintext_rule(api.scheme(prepared))
  let reducer = adapter.new_reducer(api.adapter(prepared), setup.limits)
  owner.start(
    owner.Setup(..setup, reducer:),
    option.map(budget, remaining_ms),
    fn(stream) { start(client, prepared, budget, stream, setup) },
  )
}

fn remaining_ms(budget: deadline.Deadline) -> Int {
  duration.to_milliseconds(deadline.remaining(budget))
}

fn plaintext_rule(
  client: http_gun.Client,
  scheme: http.Scheme,
) -> http_gun.Client {
  case scheme {
    http.Https -> client
    http.Http ->
      http_gun.with_destination(
        client,
        destination.default()
          |> destination.allow_loopback
          |> destination.allow_private
          |> destination.with_plaintext(destination.PlaintextToLoopbackOnly),
      )
  }
}

fn start(
  client: http_gun.Client,
  prepared: api.PreparedCall,
  budget: Option(deadline.Deadline),
  stream: owner.Stream,
  setup: owner.Setup,
) -> owner.TransportPort {
  let ready = process.new_subject()
  // Created in the semantic owner: abnormal owner death terminates this worker.
  let worker =
    process.spawn(fn() {
      cancellation.with_token(fn(token) {
        let control = process.new_subject()
        process.send(ready, #(control, token))
        let wait = case budget {
          Some(budget) -> process.receive(control, remaining_ms(budget))
          None -> Ok(process.receive_forever(control))
        }
        case wait {
          Ok(More) -> {
            let call = client |> http_gun.with_cancellation(token)
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
                        Ok(Nil) -> read(response.body, control, stream, setup)
                        Error(problem) ->
                          owner.feed_failure(
                            stream,
                            problem,
                            stream_types.RetryEvidence(
                              stream_types.ResponseCompleted,
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
                        setup.limits.error_body_bytes_limit,
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
            owner.feed_failure(
              stream,
              error.DeadlineExceeded(error.WholeCall),
              stream_types.initial_retry_evidence(),
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
        error.Stopped,
        stream_types.initial_retry_evidence(),
      )
      owner.TransportPort(fn() { Nil }, fn() { Nil })
    }
  }
}

// The owner runs its own timers and cancels the token, which ends a blocked
// read, when one of them fires.
fn read(
  source: body.Body,
  control: process.Subject(Control),
  stream: owner.Stream,
  setup: owner.Setup,
) -> Nil {
  case body.next(source) {
    Ok(body.Chunk(bytes)) ->
      case bit_array.byte_size(bytes) > setup.limits.chunk_bytes_limit {
        True ->
          owner.feed_failure(
            stream,
            error.LimitExceeded(
              limit.ChunkBytes,
              setup.limits.chunk_bytes_limit,
              bit_array.byte_size(bytes),
            ),
            stream_types.RetryEvidence(
              stream_types.RequestMayHaveReachedProvider,
              True,
              False,
            ),
          )
        False -> {
          owner.feed_chunk(stream, bytes)
          case process.receive_forever(control) {
            More -> read(source, control, stream, setup)
            Stop -> Nil
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
  limit_bytes: Int,
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
        error.Status(status, text, retry_after.from_headers(headers)),
        stream_types.RetryEvidence(stream_types.ResponseCompleted, True, False),
      )
    }
    Ok(body.Chunk(bytes)) -> {
      // Record the first observation before a timer or close can win while
      // this bounded status-body collection is still waiting.
      case size == 0 && bit_array.byte_size(bytes) > 0 {
        True -> owner.response_bytes_observed(stream)
        False -> Nil
      }
      let total = size + bit_array.byte_size(bytes)
      case total > limit_bytes {
        True ->
          owner.feed_failure(
            stream,
            error.LimitExceeded(limit.ErrorBodyBytes, limit_bytes, total),
            stream_types.RetryEvidence(
              stream_types.RequestMayHaveReachedProvider,
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
            limit_bytes,
            [bytes, ..chunks],
            total,
          )
      }
    }
    Error(failure) -> fail(stream, failure, size > 0)
  }
}

fn validate_headers(
  headers: List(#(String, String)),
) -> Result(Nil, error.Error) {
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
      Error(error.Protocol("Compressed responses are not accepted"))
    _, _ -> Error(error.Protocol("Response is not text/event-stream"))
  }
}

fn header(headers: List(#(String, String)), name: String) -> String {
  headers
  |> list.find(fn(h) { string.lowercase(h.0) == name })
  |> result.map(fn(h) { h.1 })
  |> result.unwrap("")
}

fn fail(stream: owner.Stream, failure: http_error.Failure, bytes: Bool) -> Nil {
  owner.feed_failure(
    stream,
    wire_error(failure),
    stream_types.RetryEvidence(
      case http_error.evidence(failure) {
        http_error.NotSent -> stream_types.NoRequestSent
        http_error.MaybeSent -> stream_types.RequestMayHaveReachedProvider
      },
      bytes,
      False,
    ),
  )
}

/// HTTP Gun's own deadline and cancellation map to the call's; every other
/// failure keeps HTTP Gun's opaque `Failure`.
pub fn wire_error(failure: http_error.Failure) -> error.Error {
  case http_error.reason(failure) {
    http_error.DeadlineExceeded -> error.DeadlineExceeded(error.WholeCall)
    http_error.Cancelled -> error.Cancelled
    _ -> error.Http(failure)
  }
}
