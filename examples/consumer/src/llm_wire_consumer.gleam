//// A separate package using only LLM Wire's public modules: the common path
//// first, then structured output, a tool round trip, streaming, retry
//// advice and a custom adapter. `main` runs every flow offline against
//// scripted HTTP Gun clients; nothing here contacts a provider.

import classification_consumer
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/supervision
import gleam/string
import gleam/time/duration.{type Duration}
import http_gun
import http_gun/cassette
import http_gun/config as http_config
import http_gun/testing as http_testing
import json/blueprint/codec
import llm_wire
import llm_wire/error
import llm_wire/message
import llm_wire/openai
import llm_wire/provider
import llm_wire/testing
import llm_wire/tool
import transcription_consumer

// --- the common path ---------------------------------------------------------

/// OpenAI with the default limits and timeouts.
pub fn openai_config(api_key: String) -> llm_wire.Config {
  openai.new(api_key) |> openai.config
}

pub fn question(text: String) -> llm_wire.Request(String) {
  llm_wire.request("gpt-5", [llm_wire.user(text)])
}

/// Prepare, run, and read the answer or a one-line failure.
pub fn ask(
  client: http_gun.Client,
  config: llm_wire.Config,
  text: String,
) -> Result(String, String) {
  case llm_wire.prepare(config, question(text)) {
    Error(problem) -> Error(error.describe_prepare_error(problem))
    Ok(prepared) ->
      case llm_wire.run(client, prepared) {
        Ok(llm_wire.Answer(text:, ..)) -> Ok(text)
        Ok(_) -> Error("no final answer")
        Error(failure) -> Error(llm_wire.describe_failure(failure))
      }
  }
}

// --- structured output -------------------------------------------------------

pub type Weather {
  Weather(city: String, celsius: Int)
}

pub fn weather_codec() -> codec.Codec(Weather) {
  use city <- codec.field("city", codec.string(), get: fn(w: Weather) { w.city })
  use celsius <- codec.field("celsius", codec.int(), get: fn(w: Weather) {
    w.celsius
  })
  codec.success(Weather(city:, celsius:))
}

pub fn forecast_request(city: String) -> llm_wire.Request(Weather) {
  question("Weather in " <> city <> "?")
  |> llm_wire.with_output("weather", weather_codec())
}

/// The answer is decoded into `Weather`; invalid output keeps the raw text.
pub fn forecast(
  client: http_gun.Client,
  config: llm_wire.Config,
  city: String,
) -> Result(Weather, String) {
  case llm_wire.prepare(config, forecast_request(city)) {
    Error(problem) -> Error(error.describe_prepare_error(problem))
    Ok(prepared) ->
      case llm_wire.run(client, prepared) {
        Ok(llm_wire.Answer(output:, ..)) -> Ok(output)
        Ok(_) -> Error("no structured answer")
        Error(llm_wire.Failure(
          error: error.InvalidOutput(raw_output:, failure: reason),
          ..,
        )) ->
          Error(
            "invalid output "
            <> raw_output
            <> ": "
            <> error.describe_value_failure(reason),
          )
        Error(failure) -> Error(llm_wire.describe_failure(failure))
      }
  }
}

// --- a tool round trip -------------------------------------------------------

fn city_codec() -> codec.Codec(String) {
  use city <- codec.field("city", codec.string(), get: fn(city) { city })
  codec.success(city)
}

pub fn temperature_tool() -> tool.Tool {
  tool.new("temperature", "Current temperature of a city", city_codec())
}

pub fn tool_request(text: String) -> llm_wire.Request(String) {
  question(text) |> llm_wire.with_tools([temperature_tool()])
}

/// Run `request`; on `NeedsTools`, answer every call with `lookup`, append
/// the turn and its results, and ask again, at most `rounds` times.
pub fn answer_with_tools(
  client: http_gun.Client,
  config: llm_wire.Config,
  request: llm_wire.Request(String),
  lookup: fn(String) -> String,
  rounds: Int,
) -> Result(String, String) {
  case llm_wire.prepare(config, request) {
    Error(problem) -> Error(error.describe_prepare_error(problem))
    Ok(prepared) ->
      case llm_wire.run(client, prepared) {
        Ok(llm_wire.Answer(text:, ..)) -> Ok(text)
        Ok(llm_wire.NeedsTools(turn:, ..)) if rounds > 0 -> {
          let results =
            list.map(turn.calls, fn(call) {
              case tool.decode_arguments(call, city_codec()) {
                Ok(city) -> llm_wire.tool_result(call, lookup(city))
                Error(reason) ->
                  llm_wire.tool_result(
                    call,
                    "Invalid arguments: "
                      <> error.describe_value_failure(reason),
                  )
              }
            })
          let next =
            llm_wire.append(request, [message.Assistant(turn), ..results])
          answer_with_tools(client, config, next, lookup, rounds - 1)
        }
        Ok(llm_wire.NeedsTools(..)) -> Error("too many tool rounds")
        Ok(llm_wire.OutputLimited(..)) -> Error("output limited")
        Ok(llm_wire.Refused(reason:, ..)) -> Error("refused: " <> reason)
        Error(failure) -> Error(llm_wire.describe_failure(failure))
      }
  }
}

// --- streaming ---------------------------------------------------------------

/// Stream a call, handing each text delta to `on_text`, until `Done`.
pub fn stream_text(
  client: http_gun.Client,
  prepared: llm_wire.Prepared(o),
  on_text: fn(String) -> Nil,
) -> Result(llm_wire.Outcome(o), String) {
  case llm_wire.stream(client, prepared) {
    Error(failure) -> Error(llm_wire.describe_failure(failure))
    Ok(stream) -> read(stream, on_text)
  }
}

fn read(
  stream: llm_wire.Stream(o),
  on_text: fn(String) -> Nil,
) -> Result(llm_wire.Outcome(o), String) {
  case llm_wire.next(stream) {
    Ok(llm_wire.Progress(message.TextDelta(text:, ..))) -> {
      on_text(text)
      read(stream, on_text)
    }
    Ok(llm_wire.Progress(_)) -> read(stream, on_text)
    Ok(llm_wire.Done(Ok(outcome))) -> Ok(outcome)
    Ok(llm_wire.Done(Error(failure))) ->
      Error(llm_wire.describe_failure(failure))
    Error(_) -> Error("the stream ended without an outcome")
  }
}

// --- retry advice ------------------------------------------------------------

/// Run, and run again while `advise` says another attempt may help, waiting
/// the provider's `Retry-After` or, when it named none, `fallback`. LLM Wire
/// never retries itself.
pub fn run_with_retries(
  client: http_gun.Client,
  prepared: llm_wire.Prepared(o),
  attempts: Int,
  fallback: Duration,
) -> Result(llm_wire.Outcome(o), llm_wire.Failure) {
  case llm_wire.run(client, prepared) {
    Error(failure) if attempts > 1 ->
      case llm_wire.advise(failure) {
        llm_wire.RetryAdvice(prospect: llm_wire.MayHelp, delay:) -> {
          process.sleep(
            duration.to_milliseconds(case delay {
              llm_wire.ProviderDelay(wait) -> wait
              llm_wire.Backoff -> fallback
            }),
          )
          run_with_retries(client, prepared, attempts - 1, fallback)
        }
        _ -> Error(failure)
      }
    outcome -> outcome
  }
}

// --- a custom adapter --------------------------------------------------------

type AcmeState {
  AcmeState(text: String, usage: Option(message.Usage), done: Bool)
}

/// A provider the built-in adapters do not cover: it streams `delta`
/// events and ends with `done`. The key stays inside the header closure.
pub fn acme_config(api_key: String) -> llm_wire.Config {
  provider.new(
    message.Custom("acme"),
    "https://llm.acme.test/v1",
    acme_encode,
    fn() { provider.reducer(AcmeState("", None, False), acme_step, acme_end) },
  )
  |> provider.with_headers(fn() { [#("authorization", "Bearer " <> api_key)] })
  |> provider.config
}

fn acme_encode(
  request: provider.Request,
  _tools: List(provider.ProjectedTool),
  _format: Option(provider.OutputFormat),
) -> Result(provider.Encoded, error.PrepareError) {
  let prompts =
    list.filter_map(request.messages, fn(entry) {
      case entry {
        message.User(text) -> Ok(json.string(text))
        _ -> Error(Nil)
      }
    })
  Ok(provider.encoded(
    "/generate",
    json.to_string(
      json.object([
        #("model", json.string(request.model)),
        #("prompts", json.preprocessed_array(prompts)),
      ]),
    ),
  ))
}

fn acme_step(
  state: AcmeState,
  event: provider.Event,
) -> Result(#(AcmeState, List(message.Progress)), error.Error) {
  case event.event {
    Some("delta") ->
      Ok(
        #(AcmeState(..state, text: state.text <> event.data), [
          message.TextDelta("0", event.data),
        ]),
      )
    Some("done") ->
      case int.parse(event.data) {
        Ok(tokens) -> {
          let usage = message.Usage(0, tokens, tokens)
          Ok(
            #(AcmeState(..state, usage: Some(usage), done: True), [
              message.UsageUpdate(usage),
            ]),
          )
        }
        Error(Nil) -> Error(error.Protocol("done carries a token count"))
      }
    _ -> Ok(#(state, []))
  }
}

fn acme_end(state: AcmeState) -> Option(provider.Terminal) {
  case state.done {
    True -> Some(provider.text(state.text, state.usage))
    False -> None
  }
}

// --- application wiring ------------------------------------------------------

pub fn http_policy() -> http_config.Config {
  // Each LLM call's own budget replaces the client's request timeout, so the
  // HTTP Gun defaults need no raised ceiling.
  http_config.default()
}

/// Supervise the shared client under `name`; `http_gun.named(name)` reaches
/// it from anywhere, across restarts.
pub fn http_child(
  name: process.Name(http_gun.Message),
) -> supervision.ChildSpecification(http_gun.Client) {
  http_gun.supervised(http_policy(), name)
}

/// The application's handle to the supervised client.
pub fn http_client(name: process.Name(http_gun.Message)) -> http_gun.Client {
  http_gun.named(name)
}

/// The same flow accepts live, scripted, playback and recording clients:
/// one buffered call, one early-closed stream and ten concurrent calls.
pub fn flow(client: http_gun.Client, call: llm_wire.Prepared(String)) -> Nil {
  let assert Ok(llm_wire.Answer(text: "hello", ..)) = llm_wire.run(client, call)
  let assert Ok(stream) = llm_wire.stream(client, call)
  let assert Ok(llm_wire.Progress(_)) = llm_wire.next(stream)
  let _ = llm_wire.close(stream)
  let done = process.new_subject()
  list.each(list.repeat(Nil, 10), fn(_) {
    let _ =
      process.spawn(fn() { process.send(done, llm_wire.run(client, call)) })
    Nil
  })
  list.each(list.repeat(Nil, 10), fn(_) {
    let assert Ok(Ok(llm_wire.Answer(text: "hello", ..))) =
      process.receive(done, 5000)
    Nil
  })
}

pub fn live(call: llm_wire.Prepared(String)) -> Nil {
  let assert Ok(client) = http_gun.start(http_policy())
  flow(client, call)
  http_gun.stop(client)
}

pub fn record(call: llm_wire.Prepared(String), destination: String) -> Nil {
  let assert Ok(recorded) =
    cassette.record(
      http_policy(),
      destination,
      cassette.options() |> cassette.with_max_bytes(1_000_000),
    )
  flow(recorded.client, call)
  let assert Ok(_) = cassette.finish(recorded.recording, duration.seconds(5))
  http_gun.stop(recorded.client)
}

pub fn playback(call: llm_wire.Prepared(String), path: String) -> Nil {
  let assert Ok(script) = cassette.load(path, 1_000_000)
  let assert Ok(client) = http_testing.playback(script, http_policy())
  flow(client, call)
  http_gun.stop(client)
}

// --- offline demonstration ---------------------------------------------------

fn scripted(
  exchanges: List(http_testing.Exchange),
  run: fn(http_gun.Client) -> a,
) -> a {
  let assert Ok(client) =
    http_testing.playback(http_testing.script(exchanges), http_policy())
  let result = run(client)
  http_gun.stop(client)
  result
}

fn prepared(
  config: llm_wire.Config,
  request: llm_wire.Request(o),
) -> llm_wire.Prepared(o) {
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  prepared
}

pub fn main() -> Nil {
  classification_consumer.main()
  transcription_consumer.main()
  // The common path, against OpenAI's own wire lowered from a script.
  let config = openai_config("sk-example")
  let reply = testing.events_for(message.OpenAI, testing.text("Hello!"))
  let assert Ok("Hello!") = {
    use client <- scripted([
      testing.exchange(prepared(config, question("Hi")), reply),
    ])
    ask(client, config, "Hi")
  }

  // Structured output.
  let weather =
    testing.events_for(
      message.OpenAI,
      testing.text("{\"city\":\"Paris\",\"celsius\":21}"),
    )
  let assert Ok(Weather("Paris", 21)) = {
    use client <- scripted([
      testing.exchange(prepared(config, forecast_request("Paris")), weather),
    ])
    forecast(client, config, "Paris")
  }

  // A tool round trip: the second request carries the turn and its result.
  let first = tool_request("How warm is Paris?")
  let wants_tool =
    testing.events_for(
      message.OpenAI,
      testing.tool_calls("", [
        testing.tool_call("call_1", "temperature", "{\"city\":\"Paris\"}"),
      ]),
    )
  let assert Ok(llm_wire.NeedsTools(turn:, ..)) = {
    use client <- scripted([
      testing.exchange(prepared(config, first), wants_tool),
    ])
    llm_wire.run(client, prepared(config, first))
  }
  let assert [call] = turn.calls
  let second =
    llm_wire.append(first, [
      message.Assistant(turn),
      llm_wire.tool_result(call, "21"),
    ])
  let assert Ok("It is 21 C.") = {
    use client <- scripted([
      testing.exchange(prepared(config, first), wants_tool),
      testing.exchange(
        prepared(config, second),
        testing.events_for(message.OpenAI, testing.text("It is 21 C.")),
      ),
    ])
    answer_with_tools(client, config, first, fn(_) { "21" }, 3)
  }

  // Streaming with `next`.
  let story = prepared(config, question("Tell me a story"))
  let deltas = process.new_subject()
  let assert Ok(llm_wire.Answer(text: "Once upon a time", ..)) = {
    use client <- scripted([
      testing.exchange(
        story,
        testing.events_for(message.OpenAI, testing.text("Once upon a time")),
      ),
    ])
    stream_text(client, story, process.send(deltas, _))
  }
  let assert Ok("Once upon a time") = process.receive(deltas, 0)

  // Retry advice: a rate limit with a Retry-After may help, and the second
  // attempt answers.
  let assert Ok(llm_wire.Answer(text: "back", ..)) = {
    use client <- scripted([
      testing.exchange(story, testing.rate_limited(message.OpenAI))
        |> testing.with_retry_after(duration.seconds(0)),
      testing.exchange(
        story,
        testing.events_for(message.OpenAI, testing.text("back")),
      ),
    ])
    run_with_retries(client, story, 3, duration.milliseconds(10))
  }

  // A custom adapter through `llm_wire/provider`.
  let acme = acme_config("acme-key")
  let acme_call = prepared(acme, question("Hi"))
  let assert Ok(llm_wire.Answer(text: "Hi from Acme", usage: Some(_), ..)) = {
    use client <- scripted([
      testing.exchange(
        acme_call,
        testing.events([
          "event: delta\ndata: Hi from \n\n",
          "event: delta\ndata: Acme\n\n",
          "event: done\ndata: 3\n\n",
        ]),
      ),
    ])
    llm_wire.run(client, acme_call)
  }
  let assert False = string.contains(string.inspect(acme), "acme-key")

  // The shared-client flow, scripted and then from a cassette. Concurrent
  // identical requests deliberately have identical replies; distinct
  // order-sensitive exchanges need application-controlled admission order.
  let call = prepared(testing.config(), question("hi"))
  let exchanges = list.repeat(testing.exchange(call, testing.text("hello")), 12)
  let script = http_testing.script(exchanges)
  let assert Ok(client) = http_testing.playback(script, http_policy())
  flow(client, call)
  let assert Error(llm_wire.Failure(error: error.Http(_), ..)) =
    llm_wire.run(client, call)
  http_gun.stop(client)
  let assert Ok(script) = cassette.parse(cassette.encode(script), 1_000_000)
  let assert Ok(client) = http_testing.playback(script, http_policy())
  flow(client, call)
  http_gun.stop(client)
}
