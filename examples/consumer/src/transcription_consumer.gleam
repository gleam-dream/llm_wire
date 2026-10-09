//// Public transcription common path, configuration, native values and failures.

import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import http_gun
import http_gun/config
import http_gun/testing
import llm_wire
import llm_wire/error
import llm_wire/transcribe

type Note {
  Note(id: Int, text: String)
}

fn record(
  client: http_gun.Client,
  call: transcribe.Prepared,
) -> Result(Note, llm_wire.Failure) {
  transcribe.run(client, call) |> result.map(fn(text) { Note(42, text) })
}

pub fn main() -> Nil {
  let assert Ok(audio) = transcribe.audio(<<"sample">>, "audio/flac", 1024)
  let config = transcribe.google("fixture-key")
  let assert Ok(common) =
    transcribe.prepare(config, transcribe.settings("chosen-model"), audio)
  let assert False =
    string.contains(transcribe.request_json(common), "fixture-key")
  let assert True = string.contains(transcribe.request_json(common), "verbatim")

  let configured =
    config
    |> transcribe.with_endpoint("https://proxy.example.test/transcribe")
    |> transcribe.with_request_limit(2048)
  let settings =
    transcribe.Settings("chosen-model", ["en-US", "es-ES"], transcribe.Smart)
  let assert Ok(call) = transcribe.prepare(configured, settings, audio)
  // Independent expected request, not reconstructed from the prepared input.
  let body =
    "{\"store\":false,\"model\":\"chosen-model\",\"input\":[{\"type\":\"audio\",\"data\":\"c2FtcGxl\",\"mime_type\":\"audio/flac\"}],\"generation_config\":{\"transcription_config\":{\"language_codes\":[\"en-US\",\"es-ES\"],\"mode\":\"smart\"}}}"
  let assert True = transcribe.request_json(call) == body
  let assert Ok(req) = request.to("https://proxy.example.test/transcribe")
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("x-goog-api-key", "fixture-key")
    |> request.set_header("content-type", "application/json")
    |> request.set_body(bit_array.from_string(body))
  let response =
    response.new(200)
    |> response.set_body([
      <<
        "{\"status\":\"completed\",\"steps\":[{\"type\":\"model_output\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\"}]}]}",
      >>,
    ])
  let success = testing.Respond(response, testing.Finished([]))
  let quota =
    testing.Respond(
      response.new(429) |> response.set_body([]),
      testing.Finished([]),
    )
  let assert Ok(client) =
    testing.script([
      testing.exchange(req, success),
      testing.exchange(req, quota),
      testing.exchange(req, success),
    ])
    |> testing.playback(config.default())
  let assert Ok(Note(42, "Hello")) = record(client, call)
  let assert Error(failure) = record(client, call)
  let assert error.Status(429, "", None) = failure.error
  let assert llm_wire.Completed = failure.sent
  // The failed call did not consume the following explicit attempt.
  let assert Ok(Note(42, "Hello")) = record(client, call)
  let assert Ok(stats) = http_gun.stats(client)
  let assert 0 = stats.open_bodies
  http_gun.stop(client)
  let assert Error(transcribe.AudioTooLarge(1, 2)) =
    transcribe.audio(<<1, 2>>, "audio/flac", 1)
  let assert Error(error.InvalidSetting(error.ApiKey, _)) =
    transcribe.prepare(transcribe.google(""), settings, audio)
  let assert Some(429) = case failure.error {
    error.Status(code, ..) -> Some(code)
    _ -> None
  }
  Nil
}
