//// The calls verified against the live providers. Each is defined once and
//// shared by the opt-in recorder (`llm_wire_live_record`, run by
//// `dev/record-live`) and the offline replay tests, so a cassette matches
//// the request the tests prepare. Replay uses a placeholder key: credential
//// headers are never stored and never compared.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import http_gun
import http_gun/config as http_config
import http_gun/redaction
import json/blueprint/codec
import json/blueprint/number
import json/blueprint/value.{type Value}
import llm_wire
import llm_wire/google
import llm_wire/message
import llm_wire/openai
import llm_wire/thinking
import llm_wire/tool

/// `gemini-2.5-flash` answered 404 "no longer available to new users" on
/// 2026-10-04.
pub const gemini_model = "gemini-3.8-flash"

pub const openai_model = "gpt-4.1-mini"

/// The answer of the structured scenarios: a union below an object root.
pub type Answer {
  Written(title: String, body: String)
  NoSources(reason: String)
}

/// The original Blueprint codec; the replies decode through it.
pub fn answer() -> codec.Codec(Answer) {
  codec.union({
    use written <- codec.variant(
      "Written",
      {
        use title <- codec.field("title", codec.string(), get: fn(a) { a.0 })
        use body <- codec.field("body", codec.string(), get: fn(a) { a.1 })
        codec.success(#(title, body))
      },
      fn(pair: #(String, String)) { Written(pair.0, pair.1) },
    )
    use no_sources <- codec.variant(
      "NoSources",
      {
        use reason <- codec.field("reason", codec.string(), get: fn(r) { r })
        codec.success(reason)
      },
      NoSources,
    )
    codec.match(fn(value) {
      case value {
        Written(title, body) -> written(#(title, body))
        NoSources(reason) -> no_sources(reason)
      }
    })
  })
}

/// `{"answer": Answer}`.
pub fn output() -> codec.Codec(Answer) {
  use answer <- codec.field("answer", answer(), get: fn(a) { a })
  codec.success(answer)
}

/// The nested nullable scenarios: `{"contact": Contact}`, where `phone` is
/// a nullable string and `address` a nullable object.
pub type Contact {
  Contact(name: String, phone: Option(String), address: Option(Address))
}

pub type Address {
  Address(city: String)
}

pub fn contact_output() -> codec.Codec(Contact) {
  let address = {
    use city <- codec.field("city", codec.string(), get: fn(a: Address) {
      a.city
    })
    codec.success(Address(city))
  }
  let contact = {
    use name <- codec.field("name", codec.string(), get: fn(c: Contact) {
      c.name
    })
    use phone <- codec.field(
      "phone",
      codec.nullable(codec.string()),
      get: fn(c: Contact) { c.phone },
    )
    use address <- codec.field(
      "address",
      codec.nullable(address),
      get: fn(c: Contact) { c.address },
    )
    codec.success(Contact(name, phone, address))
  }
  use contact <- codec.field("contact", contact, get: fn(c) { c })
  codec.success(contact)
}

/// The scenario of the other strict-profile refusals: an optional field, a
/// number range, a pair and `codec.value()`.
pub type Reading {
  Reading(
    label: String,
    note: Option(String),
    score: number.Number,
    point: #(Int, Int),
    extra: Value,
  )
}

pub fn reading_output() -> codec.Codec(Reading) {
  let assert Ok(zero) = number.from_int(0)
  let assert Ok(one) = number.from_int(1)
  use label <- codec.field("label", codec.string(), get: fn(r: Reading) {
    r.label
  })
  use note <- codec.optional_field("note", codec.string(), get: fn(r: Reading) {
    r.note
  })
  use score <- codec.field(
    "score",
    codec.number_between(zero, one),
    get: fn(r: Reading) { r.score },
  )
  use point <- codec.field(
    "point",
    codec.pair(codec.int(), codec.int()),
    get: fn(r: Reading) { r.point },
  )
  use extra <- codec.field("extra", codec.value(), get: fn(r: Reading) {
    r.extra
  })
  codec.success(Reading(label, note, score, point, extra))
}

/// The tool of the tool-call scenario.
pub fn weather_tool() -> tool.Tool {
  tool.new("get_weather", "Current weather for a city", city())
}

/// The weather tool's input codec: `{"city": String}`.
pub fn city() -> codec.Codec(String) {
  use city <- codec.field("city", codec.string(), get: fn(c) { c })
  codec.success(city)
}

/// What a cassette never stores: the credential headers, OpenAI's account
/// identifiers and a `key` query parameter.
pub fn redaction() -> redaction.Redaction {
  redaction.default()
  |> redaction.with_headers(["openai-organization", "openai-project"])
  |> redaction.with_query_parameters(["key"])
}

/// The HTTP Gun configuration of both the recording and the playback client.
pub fn http() -> http_config.Config {
  http_config.default() |> http_config.with_redaction(redaction())
}

pub type Scenario {
  GoogleWritten
  GoogleNoSources
  GoogleText
  GoogleTool
  GoogleNullableNull
  GoogleNullableValue
  GoogleWideSchema
  OpenAiWritten
  OpenAiNoSources
  GoogleThinkingLevel
  GoogleThoughtLimit
  OpenAiThinkingLevel
  OpenAiFilePdf
  OpenAiOptionalNull
  OpenAiOptionalValue
  OpenAiStoreFalse
  OpenAiToolRound
}

pub fn all() -> List(Scenario) {
  [
    GoogleWritten,
    GoogleNoSources,
    GoogleText,
    GoogleTool,
    GoogleNullableNull,
    GoogleNullableValue,
    GoogleWideSchema,
    OpenAiWritten,
    OpenAiNoSources,
    GoogleThinkingLevel,
    GoogleThoughtLimit,
    OpenAiThinkingLevel,
    OpenAiFilePdf,
    OpenAiOptionalNull,
    OpenAiOptionalValue,
    OpenAiStoreFalse,
    OpenAiToolRound,
  ]
}

pub fn name(scenario: Scenario) -> String {
  case scenario {
    GoogleWritten -> "google-union-written"
    GoogleNoSources -> "google-union-no-sources"
    GoogleText -> "google-text-stream"
    GoogleTool -> "google-tool-call"
    GoogleNullableNull -> "google-nullable-null"
    GoogleNullableValue -> "google-nullable-value"
    GoogleWideSchema -> "google-wide-schema"
    OpenAiWritten -> "openai-union-written"
    OpenAiNoSources -> "openai-union-no-sources"
    GoogleThinkingLevel -> "google-thinking-level"
    GoogleThoughtLimit -> "google-thought-limit"
    OpenAiThinkingLevel -> "openai-thinking-level"
    OpenAiFilePdf -> "openai-file-pdf"
    OpenAiOptionalNull -> "openai-optional-null"
    OpenAiOptionalValue -> "openai-optional-value"
    OpenAiStoreFalse -> "openai-store-false"
    OpenAiToolRound -> "openai-tool-round"
  }
}

pub fn from_name(text: String) -> Result(Scenario, Nil) {
  list.find(all(), fn(scenario) { name(scenario) == text })
}

pub fn path(scenario: Scenario) -> String {
  "test/cassettes/live/" <> name(scenario) <> ".json"
}

pub fn is_google(scenario: Scenario) -> Bool {
  case scenario {
    GoogleWritten
    | GoogleNoSources
    | GoogleText
    | GoogleTool
    | GoogleNullableNull
    | GoogleNullableValue
    | GoogleWideSchema
    | GoogleThinkingLevel
    | GoogleThoughtLimit -> True
    OpenAiWritten
    | OpenAiNoSources
    | OpenAiThinkingLevel
    | OpenAiFilePdf
    | OpenAiOptionalNull
    | OpenAiOptionalValue
    | OpenAiStoreFalse
    | OpenAiToolRound -> False
  }
}

pub fn google_config(key: String) -> llm_wire.Config {
  google.new(key) |> google.config
}

fn openai_config(key: String) -> llm_wire.Config {
  openai.new(key) |> openai.config
}

const written_prompt =
  "Reply with the Written variant: title \"Tides\", body one short sentence on why ocean tides happen."

const no_sources_prompt =
  "You have no sources about my breakfast today. Reply with the NoSources variant and a reason of at most ten words."

fn structured(
  config: llm_wire.Config,
  model: String,
  prompt: String,
  max_tokens: Int,
) -> llm_wire.Prepared(Answer) {
  let request =
    llm_wire.request(model, [llm_wire.user(prompt)])
    |> llm_wire.with_max_tokens(max_tokens)
    |> llm_wire.with_output("answer", output())
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  prepared
}

/// Gemini Flash counts its thinking against `maxOutputTokens`, so its
/// bound leaves room for both.
pub fn structured_call(
  scenario: Scenario,
  key: String,
) -> llm_wire.Prepared(Answer) {
  case scenario {
    GoogleWritten ->
      structured(google_config(key), gemini_model, written_prompt, 2048)
    GoogleNoSources ->
      structured(google_config(key), gemini_model, no_sources_prompt, 2048)
    OpenAiWritten ->
      structured(openai_config(key), openai_model, written_prompt, 200)
    OpenAiNoSources ->
      structured(openai_config(key), openai_model, no_sources_prompt, 200)
    _ -> panic as "not a union scenario"
  }
}

pub fn text_call(key: String) -> llm_wire.Prepared(String) {
  let request =
    llm_wire.request(gemini_model, [
      llm_wire.user(
        "Write the numbers one to twenty in words, separated by commas, and nothing else.",
      ),
    ])
    |> llm_wire.with_max_tokens(2048)
  let assert Ok(prepared) = llm_wire.prepare(google_config(key), request)
  prepared
}

pub fn tool_request() -> llm_wire.Request(String) {
  llm_wire.request(gemini_model, [
    llm_wire.user("What is the weather in Paris? Use the get_weather tool."),
  ])
  |> llm_wire.with_max_tokens(2048)
  |> llm_wire.with_tools([weather_tool()])
}

pub fn tool_call(key: String) -> llm_wire.Prepared(String) {
  let assert Ok(prepared) = llm_wire.prepare(google_config(key), tool_request())
  prepared
}

const nullable_null_prompt =
  "Fill in the contact for Ada Lovelace. Her phone number and address are unknown: give null for both."

const nullable_value_prompt =
  "Fill in the contact for Bob Stone. His phone number is 555-0100 and he lives in Paris."

/// A nested nullable string and a nullable object, null or not.
pub fn nullable_call(
  scenario: Scenario,
  key: String,
) -> llm_wire.Prepared(Contact) {
  let prompt = case scenario {
    GoogleNullableNull -> nullable_null_prompt
    GoogleNullableValue -> nullable_value_prompt
    _ -> panic as "not a nullable scenario"
  }
  let request =
    llm_wire.request(gemini_model, [llm_wire.user(prompt)])
    |> llm_wire.with_max_tokens(2048)
    |> llm_wire.with_output("contact", contact_output())
  let assert Ok(prepared) = llm_wire.prepare(google_config(key), request)
  prepared
}

const wide_prompt =
  "Report a reading with label \"north\", score 0.75, point [3, 4] and extra {\"unit\": \"cm\"}. Leave out the note."

/// An optional field, a number range, a pair and `codec.value()` in one
/// Gemini schema.
pub fn wide_call(key: String) -> llm_wire.Prepared(Reading) {
  let request =
    llm_wire.request(gemini_model, [llm_wire.user(wide_prompt)])
    |> llm_wire.with_max_tokens(2048)
    |> llm_wire.with_output("reading", reading_output())
  let assert Ok(prepared) = llm_wire.prepare(google_config(key), request)
  prepared
}

/// The smallest OpenAI reasoning model on OpenAI's models page, for the
/// thinking-level scenario; the union scenarios keep `openai_model`.
pub const openai_reasoning_model = "gpt-6-luna"

const thinking_prompt = "What is the capital of France? Answer in one word."

const thought_limit_prompt =
  "Work out 17 multiplied by 23 step by step, then give the result."

/// The thinking scenarios (ADR 0020): a Google level, a Google response the
/// limit cuts off while thinking (dash-crm's case at a small limit, with no
/// level set), and an OpenAI reasoning effort.
pub fn thinking_call(
  scenario: Scenario,
  key: String,
) -> llm_wire.Prepared(String) {
  let #(config, request) = case scenario {
    GoogleThinkingLevel -> #(
      google_config(key),
      llm_wire.request(gemini_model, [llm_wire.user(thinking_prompt)])
        |> llm_wire.with_max_tokens(2048)
        |> llm_wire.with_thinking_level(thinking.Low),
    )
    GoogleThoughtLimit -> #(
      google_config(key),
      llm_wire.request(gemini_model, [llm_wire.user(thought_limit_prompt)])
        |> llm_wire.with_max_tokens(64),
    )
    OpenAiThinkingLevel -> #(
      openai_config(key),
      llm_wire.request(openai_reasoning_model, [llm_wire.user(thinking_prompt)])
        |> llm_wire.with_thinking_level(thinking.Low),
    )
    _ -> panic as "not a thinking scenario"
  }
  let assert Ok(prepared) = llm_wire.prepare(config, request)
  prepared
}

// --- OpenAI Responses on dash-crm's model (ADR 0021) -------------------------

/// The model dash-crm's agents use. OpenAI says to leave out `temperature`
/// and `top_p` for it, so no scenario sets them.
pub const openai_sol_model = "gpt-6.2-sol"

/// dash-crm's OpenAI configuration: responses are not stored.
pub fn sol_config(key: String) -> llm_wire.Config {
  openai.new(key) |> openai.with_store(False) |> openai.config
}

fn sol_request(prompt: List(message.Content)) -> llm_wire.Request(String) {
  llm_wire.request(openai_sol_model, [message.UserParts(prompt)])
  |> llm_wire.with_max_tokens(4096)
}

/// A one-page PDF of 622 bytes reading "Invoice A-17" and "Total due: 42.50
/// EUR", written by hand so it carries nothing else.
pub const invoice_pdf =
  "JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvUmVzb3VyY2VzIDw8IC9Gb250IDw8IC9GMSA1IDAgUiA+PiA+PiAvQ29udGVudHMgNCAwIFIgPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCA3OCA+PgpzdHJlYW0KQlQgL0YxIDE4IFRmIDcyIDcyMCBUZCAoSW52b2ljZSBBLTE3KSBUaiAwIC0yOCBUZCAoVG90YWwgZHVlOiA0Mi41MCBFVVIpIFRqIEVUCmVuZHN0cmVhbQplbmRvYmoKNSAwIG9iago8PCAvVHlwZSAvRm9udCAvU3VidHlwZSAvVHlwZTEgL0Jhc2VGb250IC9IZWx2ZXRpY2EgPj4KZW5kb2JqCnhyZWYKMCA2CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAwOSAwMDAwMCBuIAowMDAwMDAwMDU4IDAwMDAwIG4gCjAwMDAwMDAxMTUgMDAwMDAgbiAKMDAwMDAwMDI0MSAwMDAwMCBuIAowMDAwMDAwMzY5IDAwMDAwIG4gCnRyYWlsZXIKPDwgL1NpemUgNiAvUm9vdCAxIDAgUiA+PgpzdGFydHhyZWYKNDM5CiUlRU9GCg=="

pub type Invoice {
  Invoice(number: String, total: String, currency: String)
}

pub fn invoice_output() -> codec.Codec(Invoice) {
  use number <- codec.field("number", codec.string(), get: fn(i: Invoice) {
    i.number
  })
  use total <- codec.field("total", codec.string(), get: fn(i: Invoice) {
    i.total
  })
  use currency <- codec.field("currency", codec.string(), get: fn(i: Invoice) {
    i.currency
  })
  codec.success(Invoice(number:, total:, currency:))
}

/// A PDF in an `InlineFilePart`, read into a structured answer.
pub fn pdf_call(key: String) -> llm_wire.Prepared(Invoice) {
  let request =
    sol_request([
      message.TextPart(
        "Read the attached invoice. Give its number, the total due as written, without the currency, and the currency code.",
      ),
      message.InlineFilePart("application/pdf", "invoice.pdf", invoice_pdf),
    ])
    |> llm_wire.with_output("invoice", invoice_output())
  let assert Ok(prepared) = llm_wire.prepare(sol_config(key), request)
  prepared
}

/// `{"person": {"name": String, "nickname"?: String}}`: an optional field
/// below the root, sent to OpenAI as required and nullable.
pub type Person {
  Person(name: String, nickname: Option(String))
}

pub fn person_output() -> codec.Codec(Person) {
  let person = {
    use name <- codec.field("name", codec.string(), get: fn(p: Person) {
      p.name
    })
    use nickname <- codec.optional_field(
      "nickname",
      codec.string(),
      get: fn(p: Person) { p.nickname },
    )
    codec.success(Person(name:, nickname:))
  }
  use person <- codec.field("person", person, get: fn(p) { p })
  codec.success(person)
}

const optional_null_prompt =
  "Fill in the person Ada Lovelace. She has no nickname, so give no nickname."

const optional_value_prompt =
  "Fill in the person Robert Stone. His nickname is Bobby."

/// An optional field answered absent and answered present.
pub fn optional_call(
  scenario: Scenario,
  key: String,
) -> llm_wire.Prepared(Person) {
  let prompt = case scenario {
    OpenAiOptionalNull -> optional_null_prompt
    OpenAiOptionalValue -> optional_value_prompt
    _ -> panic as "not an optional-field scenario"
  }
  let request =
    sol_request([message.TextPart(prompt)])
    |> llm_wire.with_output("person", person_output())
  let assert Ok(prepared) = llm_wire.prepare(sol_config(key), request)
  prepared
}

/// A plain answer with `"store": false`.
pub fn store_call(key: String) -> llm_wire.Prepared(String) {
  let assert Ok(prepared) =
    llm_wire.prepare(
      sol_config(key),
      sol_request([message.TextPart(thinking_prompt)]),
    )
  prepared
}

/// The first request of the tool round: medium reasoning, unstored, with
/// the weather tool. The puzzle makes the model reason before it calls the
/// tool, so the first response carries a reasoning item the follow-up
/// leaves out.
pub fn tool_round_request() -> llm_wire.Request(String) {
  sol_request([
    message.TextPart(
      "Which European capital is an anagram of the letters S, I, R, P, A? Reason it out, call get_weather for that city, then answer in one sentence.",
    ),
  ])
  |> llm_wire.with_thinking_level(thinking.Medium)
  |> llm_wire.with_tools([weather_tool()])
}

/// The tool's output the scenario answers every call with.
pub const forecast = "{\"forecast\":\"sunny, 21 C\"}"

/// The two exchanges of the tool round: the call, then its output and the
/// final answer. The follow-up replays the turn's calls as `function_call`
/// items with `call_id` only and no reasoning item, since encrypted
/// reasoning is not carried (ADR 0021). The second outcome is `None` when
/// the first did not ask for a tool.
pub fn tool_round(
  client: http_gun.Client,
  key: String,
) -> Result(
  #(llm_wire.Outcome(String), Option(llm_wire.Outcome(String))),
  llm_wire.Failure,
) {
  let config = sol_config(key)
  let assert Ok(first) = llm_wire.prepare(config, tool_round_request())
  use outcome <- result.try(llm_wire.run(client, first))
  case outcome {
    llm_wire.NeedsTools(turn:, ..) -> {
      let results =
        list.map(turn.calls, fn(call) { llm_wire.tool_result(call, forecast) })
      let follow_up =
        llm_wire.append(tool_round_request(), [
          message.Assistant(turn),
          ..results
        ])
      let assert Ok(second) = llm_wire.prepare(config, follow_up)
      llm_wire.run(client, second)
      |> result.map(fn(answer) { #(outcome, Some(answer)) })
    }
    _ -> Ok(#(outcome, None))
  }
}
