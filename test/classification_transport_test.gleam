import classification_support as support
import gleam/erlang/process
import gleam/list
import gleam/option.{None}
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/config as http_config
import json/blueprint/value
import llm_wire
import llm_wire/classify
import llm_wire/classify/question
import llm_wire/error

fn request() -> classify.Request(question.Noul) {
  classify.request(
    "jev-latest",
    value.String("sample"),
    question.ask("correct", question.noul(value.String("correct?"), None)),
  )
}

fn post(
  config: support.Config,
) -> Result(classify.Outcome(question.Noul), llm_wire.Failure) {
  let prepared = classify.prepare(config.settings, request()) |> should.be_ok
  classify.run(config.http, prepared)
}

pub fn credentials_and_endpoints_are_checked_locally_test() {
  list.each(["", "\r\nsecret", "secret\u{0}"], fn(key) {
    classify.prepare(classify.typesafe(fn() { key }), request())
    |> should.be_error
  })
  list.each(
    [
      "http://example.com/v1/systemone",
      "https://name:secret@example.com/api",
      "https://example.com/api?secret=1",
      "https://example.com/api#fragment",
      "https://example.com/a\nb",
    ],
    fn(url) {
      classify.prepare(
        support.settings() |> classify.with_endpoint(url),
        request(),
      )
      |> should.be_error
    },
  )
}

pub fn status_and_redirects_are_not_retried_and_keep_provider_delay_test() {
  use url <- support.fixture
  let failed = post(support.config(url, "/busy")) |> should.be_error
  failed.sent |> should.equal(llm_wire.Completed)
  let assert error.Status(429, _, _) = failed.error
  llm_wire.advise(failed)
  |> should.equal(llm_wire.RetryAdvice(
    llm_wire.MayHelp,
    llm_wire.ProviderDelay(duration.seconds(9)),
  ))
  let redirected = post(support.config(url, "/redirect")) |> should.be_error
  let assert error.Status(307, _, _) = redirected.error
  support.stats(url, "calls") |> should.equal(2)
}

pub fn unsent_request_and_lost_or_oversize_response_keep_evidence_test() {
  use url <- support.fixture
  let small =
    support.http_with(
      http_config.default() |> http_config.with_max_request_body_bytes(16),
    )
  let failed = post(support.config_over(small, url, "/busy")) |> should.be_error
  failed.sent |> should.equal(llm_wire.NotSent)
  support.stats(url, "calls") |> should.equal(0)
  let http =
    support.http_with(
      http_config.default() |> http_config.with_max_header_bytes(1024),
    )
  list.each(["/large", "/drop", "/headers"], fn(path) {
    let cfg = support.config_over(http, url, path)
    let cfg =
      support.Config(
        ..cfg,
        settings: classify.with_response_limit(cfg.settings, 1024),
      )
    let failed = post(cfg) |> should.be_error
    failed.sent |> should.equal(llm_wire.MaybeSent)
  })
  support.stats(url, "calls") |> should.equal(3)
}

pub fn deadlines_and_owner_loss_close_the_actual_http_connection_test() {
  use url <- support.fixture
  let config = support.config(url, "/hold")
  let failed =
    post(
      support.Config(
        ..config,
        settings: classify.with_timeout(
          config.settings,
          llm_wire.After(duration.milliseconds(100)),
        ),
      ),
    )
    |> should.be_error
  failed.sent |> should.equal(llm_wire.MaybeSent)
  await_stat(url, "disconnected", 1, 100)
  let owner =
    process.spawn_unlinked(fn() {
      let _ = post(config)
      Nil
    })
  await_stat(url, "calls", 2, 100)
  process.kill(owner)
  await_stat(url, "disconnected", 2, 100)
}

pub fn refused_connection_is_proven_before_dispatch_test() {
  let #(server, url) = support.start()
  support.stop(server)
  let failed = post(support.config(url, "/v1/systemone")) |> should.be_error
  failed.sent |> should.equal(llm_wire.NotSent)
}

pub fn caller_destination_policy_applies_and_secrets_do_not_print_test() {
  use url <- support.fixture
  let http = http_gun.start(http_config.default()) |> should.be_ok
  let cfg = support.config_over(http, url, "/busy")
  let failed = post(cfg) |> should.be_error
  failed.sent |> should.equal(llm_wire.NotSent)
  string.contains(llm_wire.describe_failure(failed), "test-key")
  |> should.be_false
  string.contains(string.inspect(cfg), "test-key") |> should.be_false
  support.stats(url, "calls") |> should.equal(0)
}

fn await_stat(url: String, key: String, expected: Int, left: Int) -> Nil {
  case support.stats(url, key) == expected, left {
    True, _ -> Nil
    False, 0 -> panic as "HTTP fixture never observed expected event"
    False, _ -> {
      process.sleep(10)
      await_stat(url, key, expected, left - 1)
    }
  }
}
