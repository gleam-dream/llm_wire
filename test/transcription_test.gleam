//// Native Transcription behavior rules: admission, result and transport.
//// Public protocol oracles use HTTP Gun playback; no remote provider calls.

import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/cancellation
import http_gun/config
import http_gun/deadline
import http_gun/error
import http_gun/testing
import llm_wire
import llm_wire/error as wire_error
import llm_wire/telemetry
import llm_wire/transcribe as transcription
import sinal
import sinal/correlation

const expected_text = "Vou abrir uma cafeteria no Campo Belo. Vamos vender café e pão de queijo."

// Independent request oracle copied from the existing Elixir adapter's fields.
const expected_body = "{\"store\":false,\"model\":\"gemini-3.5-transcribe\",\"input\":[{\"type\":\"audio\",\"data\":\"YXVkaW8gYnl0ZXM=\",\"mime_type\":\"audio/webm\"}],\"generation_config\":{\"transcription_config\":{\"language_codes\":[\"pt-BR\"],\"mode\":{\"type\":\"verbatim\"}}}}"

fn credentials() -> transcription.Config {
  transcription.google("synthetic-key")
}

fn settings() -> transcription.Settings {
  transcription.Settings(
    "gemini-3.5-transcribe",
    ["pt-BR"],
    transcription.Verbatim,
  )
}

fn audio() -> transcription.Audio {
  let assert Ok(value) =
    transcription.audio(<<"audio bytes">>, "audio/webm", 100)
  value
}

fn expected_request() -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to("https://generativelanguage.googleapis.com/v1beta/interactions")
  req
  |> request.set_method(http.Post)
  |> request.set_header("x-goog-api-key", "synthetic-key")
  |> request.set_header("content-type", "application/json")
  |> request.set_body(bit_array.from_string(expected_body))
}

fn completed() -> testing.Reply {
  let body =
    "{\"status\":\"completed\",\"steps\":[{\"type\":\"model_output\",\"content\":[{\"type\":\"text\",\"text\":\""
    <> expected_text
    <> "\"}]}]}"
  testing.Respond(
    response.new(200) |> response.set_body([bit_array.from_string(body)]),
    testing.Finished([]),
  )
}

fn playback_client(replies: List(testing.Reply)) -> http_gun.Client {
  let assert Ok(client) =
    replies
    |> list.map(fn(reply) { testing.exchange(expected_request(), reply) })
    |> testing.script
    |> testing.playback(config.default())
  client
}

fn run(client: http_gun.Client) -> Result(String, llm_wire.Failure) {
  let assert Ok(prepared) =
    transcription.prepare(credentials(), settings(), audio())
  transcription.run(client, prepared)
}

pub fn preserves_the_request_and_recorded_transcript_test() -> Nil {
  transcription.prepare(credentials(), settings(), audio())
  |> result.map(transcription.request_json)
  |> should.equal(Ok(expected_body))
  let client = playback_client([completed()])
  run(client) |> should.equal(Ok(expected_text))
  let assert Ok(stats) = http_gun.stats(client)
  stats.open_bodies |> should.equal(0)
  http_gun.stop(client)
}

pub fn input_validation_precedes_encoding_and_io_test() -> Nil {
  let assert Error(wire_error.InvalidSetting(wire_error.ApiKey, _)) =
    transcription.prepare(transcription.google(" \n "), settings(), audio())
  transcription.audio(<<>>, "audio/webm", 100)
  |> should.equal(Error(transcription.InvalidAudio))
  transcription.audio(<<1:size(1)>>, "audio/webm", 100)
  |> should.equal(Error(transcription.InvalidAudio))
  transcription.audio(<<"x">>, "audio/webm", 0)
  |> should.equal(Error(transcription.InvalidLimit))
  transcription.audio(<<"xx">>, "audio/webm", 1)
  |> should.equal(Error(transcription.AudioTooLarge(1, 2)))
  transcription.audio(<<"x">>, "text/plain", 100)
  |> should.equal(Error(transcription.UnsupportedMime))
  list.each(["audio/webm", "audio/m4a", "audio/ogg", "audio/wav"], fn(mime) {
    transcription.audio(<<"x">>, mime, 1) |> should.be_ok
  })
  let client = playback_client([completed()])
  let assert Error(wire_error.InvalidSetting(wire_error.Model, _)) =
    transcription.prepare(
      credentials(),
      transcription.Settings(" ", [], transcription.Verbatim),
      audio(),
    )
  run(client) |> should.equal(Ok(expected_text))
  http_gun.stop(client)
}

pub fn rejects_unfinished_empty_and_malformed_output_test() -> Nil {
  list.each(
    [
      "{\"status\":\"completed\",\"steps\":[]}",
      "{\"status\":\"in_progress\",\"steps\":[]}",
      "{\"status\":\"completed\",\"steps\":null}",
      "{\"status\":\"completed\",\"steps\":[{\"type\":\"model_output\",\"content\":[{\"type\":\"text\",\"text\":42}]}]}",
      "{}", "not JSON",
    ],
    fn(body) {
      let client = playback_client([reply(body), completed()])
      let assert Error(failure) = run(client)
      wire_error.kind(failure.error)
      |> should.equal(wire_error.UnusableResponse)
      failure.sent |> should.equal(llm_wire.Completed)
      run(client) |> should.equal(Ok(expected_text))
      http_gun.stop(client)
    },
  )
}

fn reply(body: String) -> testing.Reply {
  testing.Respond(
    response.new(200) |> response.set_body([bit_array.from_string(body)]),
    testing.Finished([]),
  )
}

pub fn model_text_is_joined_and_trimmed_without_reasoning_test() -> Nil {
  let body =
    "{\"status\":\"completed\",\"steps\":[{\"type\":\"thought\",\"content\":[{\"type\":\"text\",\"text\":\"private\"}]},{\"type\":\"model_output\",\"content\":[{\"type\":\"text\",\"text\":\"  Café \"},{\"type\":\"image\"},{\"type\":\"text\",\"text\":\"azul  \"}]}]}"
  let client = playback_client([reply(body)])
  run(client) |> should.equal(Ok("Café azul"))
  http_gun.stop(client)
}

pub fn status_and_uncertain_transport_failures_never_retry_test() -> Nil {
  let quota =
    testing.Respond(
      response.new(429)
        |> response.set_header("retry-after", "30")
        |> response.set_body([<<"private provider body">>]),
      testing.Finished([]),
    )
  let client = playback_client([quota, completed()])
  let assert Error(failure) = run(client)
  failure.error
  |> should.equal(wire_error.Status(429, "", Some(duration.seconds(30))))
  failure.sent |> should.equal(llm_wire.Completed)
  run(client) |> should.equal(Ok(expected_text))
  http_gun.stop(client)
  let failure = error.new(error.DeadlineExceeded, error.MaybeSent)
  let client = playback_client([testing.Reject(failure), completed()])
  let assert Error(observed) = run(client)
  observed.error |> should.equal(wire_error.Http(failure))
  observed.sent |> should.equal(llm_wire.MaybeSent)
  run(client) |> should.equal(Ok(expected_text))
  http_gun.stop(client)
}

pub fn borrowed_view_keeps_cancellation_and_deadline_test() -> Nil {
  let client = playback_client([completed()])
  let outcome = {
    use token <- cancellation.with_token
    cancellation.cancel(token)
    run(http_gun.with_cancellation(client, token))
  }
  let assert Error(llm_wire.Failure(error: wire_error.Http(failure), ..)) =
    outcome
  error.kind(failure) |> should.equal(error.CancelledLocally)
  error.evidence(failure) |> should.equal(error.NotSent)
  let expired = deadline.after(duration.milliseconds(0))
  let assert Error(llm_wire.Failure(error: wire_error.Http(failure), ..)) =
    run(http_gun.with_deadline(client, expired))
  error.kind(failure) |> should.equal(error.TimedOut)
  error.evidence(failure) |> should.equal(error.NotSent)
  run(client) |> should.equal(Ok(expected_text))
  http_gun.stop(client)
}

pub fn response_limits_close_the_body_and_never_accept_truncation_test() -> Nil {
  let client = playback_client([completed(), completed(), completed()])
  let assert Error(llm_wire.Failure(error: wire_error.Http(failure), ..)) =
    run(http_gun.with_body_limit(client, 8, http_gun.Fail))
  error.kind(failure) |> should.equal(error.TooLarge)
  error.status(failure) |> should.equal(Some(200))
  let assert Error(truncated) =
    run(http_gun.with_body_limit(client, 8, http_gun.Truncate))
  wire_error.kind(truncated.error) |> should.equal(wire_error.UnusableResponse)
  truncated.sent |> should.equal(llm_wire.MaybeSent)
  run(client) |> should.equal(Ok(expected_text))
  let assert Ok(stats) = http_gun.stats(client)
  stats.open_bodies |> should.equal(0)
  http_gun.stop(client)
}

pub fn caller_chooses_model_language_and_mode_test() -> Nil {
  let assert Ok(req) =
    transcription.prepare(
      credentials(),
      transcription.Settings("configured-model", ["en-US"], transcription.Smart),
      audio(),
    )
  transcription.request_json(req)
  |> should.equal(
    "{\"store\":false,\"model\":\"configured-model\",\"input\":[{\"type\":\"audio\",\"data\":\"YXVkaW8gYnl0ZXM=\",\"mime_type\":\"audio/webm\"}],\"generation_config\":{\"transcription_config\":{\"language_codes\":[\"en-US\"],\"mode\":\"smart\"}}}",
  )
}

pub fn endpoint_and_encoded_limit_are_admitted_before_execution_test() -> Nil {
  list.each(
    [
      "http://localhost/transcribe",
      "https://host",
      "https://a@host/path",
      "https://host/path?q=secret",
      "https://host/path#part",
      "https://host:0/path",
      "https://host/path\n",
    ],
    fn(endpoint) {
      let assert Error(wire_error.InvalidSetting(wire_error.Endpoint, _)) =
        transcription.prepare(
          credentials() |> transcription.with_endpoint(endpoint),
          settings(),
          audio(),
        )
      Nil
    },
  )
  let assert Error(wire_error.InvalidSetting(wire_error.LimitSetting(_), _)) =
    transcription.prepare(
      credentials() |> transcription.with_request_limit(0),
      settings(),
      audio(),
    )
  let assert Error(wire_error.RequestTooLarge(_, 8, _)) =
    transcription.prepare(
      credentials() |> transcription.with_request_limit(8),
      settings(),
      audio(),
    )
  let custom =
    credentials()
    |> transcription.with_endpoint("https://proxy.example.test/transcribe")
  let assert Ok(prepared) = transcription.prepare(custom, settings(), audio())
  let req =
    expected_request()
    |> request.set_host("proxy.example.test")
    |> request.set_path("/transcribe")
  let assert Ok(client) =
    testing.script([testing.exchange(req, completed())])
    |> testing.playback(config.default())
  transcription.run(client, prepared) |> should.equal(Ok(expected_text))
  http_gun.stop(client)
}

pub fn all_documented_mime_names_are_admitted_without_codec_claims_test() -> Nil {
  list.each(
    [
      "audio/wav",
      "audio/mp3",
      "audio/aiff",
      "audio/aac",
      "audio/ogg",
      "audio/flac",
      "audio/mpeg",
      "audio/m4a",
      "audio/l16",
      "audio/opus",
      "audio/alaw",
      "audio/mulaw",
      "audio/webm",
    ],
    fn(mime) { transcription.audio(<<"x">>, mime, 1) |> should.be_ok },
  )
  transcription.settings("configured-model")
  |> should.equal(transcription.Settings(
    "configured-model",
    [],
    transcription.Verbatim,
  ))
}

pub fn credentials_and_correlated_observations_exclude_content_test() -> Nil {
  let config = credentials()
  let assert Ok(prepared) = transcription.prepare(config, settings(), audio())
  string.contains(string.inspect(config), "synthetic-key") |> should.be_false
  string.contains(string.inspect(prepared), "synthetic-key") |> should.be_false
  let correlation = correlation.unique()
  let seen = process.new_subject()
  let observer =
    sinal.observe(telemetry.event(), fn(_, meta) {
      case meta.correlation == Some(correlation) {
        True -> process.send(seen, meta)
        False -> Nil
      }
    })
  let client = playback_client([completed(), completed()])
  let execute = fn() {
    transcription.run(http_gun.with_correlation(client, correlation), prepared)
    |> should.equal(Ok(expected_text))
    let assert Ok(first) = process.receive(seen, 1000)
    first.stage |> should.equal(telemetry.Started)
    list.each(
      [telemetry.RequestSent, telemetry.Terminal, telemetry.Cleanup],
      fn(stage) {
        let assert Ok(next) = process.receive(seen, 1000)
        next.stage |> should.equal(stage)
        next.call |> should.equal(first.call)
        next.correlation |> should.equal(Some(correlation))
        let printed = string.inspect(next)
        string.contains(printed, "synthetic-key") |> should.be_false
        string.contains(printed, expected_text) |> should.be_false
        string.contains(printed, "YXVkaW8gYnl0ZXM=") |> should.be_false
      },
    )
    first.call
  }
  let first = execute()
  let second = execute()
  { first != second } |> should.be_true
  let _ = sinal.detach(observer)
  http_gun.stop(client)
}

pub fn invalid_utf8_and_excessive_json_depth_never_become_text_test() -> Nil {
  let deep = string.repeat("[", 65) <> "0" <> string.repeat("]", 65)
  let invalid =
    testing.Respond(
      response.new(200) |> response.set_body([<<255>>]),
      testing.Finished([]),
    )
  let client = playback_client([invalid, reply(deep), completed()])
  list.each([1, 2], fn(_) {
    let assert Error(failure) = run(client)
    failure.sent |> should.equal(llm_wire.Completed)
    wire_error.kind(failure.error) |> should.equal(wire_error.UnusableResponse)
  })
  run(client) |> should.equal(Ok(expected_text))
  http_gun.stop(client)
}
