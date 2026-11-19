//// Documents and optional answer fields: send a PDF as a file part, ask for a
//// structured answer whose codec has optional fields, and keep OpenAI from
//// storing the response.

import gleam/io
import gleam/option.{type Option, None}
import gleam/string
import json/blueprint/codec
import llm_wire
import llm_wire/error
import llm_wire/limit
import llm_wire/message
import llm_wire/openai
import llm_wire/testing
import usage_support.{prepared, scripted}

pub type Invoice {
  Invoice(number: String, due_date: Option(String), notes: List(Note))
}

pub type Note {
  Note(text: String, page: Option(Int))
}

fn note_codec() -> codec.Codec(Note) {
  use text <- codec.field("text", codec.string(), get: fn(n: Note) { n.text })
  use page <- codec.optional_field("page", codec.int(), get: fn(n: Note) {
    n.page
  })
  codec.success(Note(text:, page:))
}

/// `due_date` and each note's `page` are optional. OpenAI and Anthropic are
/// sent them as required and nullable; a `null` in the answer reads as
/// absent.
pub fn invoice_codec() -> codec.Codec(Invoice) {
  use number <- codec.field("number", codec.string(), get: fn(i: Invoice) {
    i.number
  })
  use due_date <- codec.optional_field(
    "due_date",
    codec.string(),
    get: fn(i: Invoice) { i.due_date },
  )
  use notes <- codec.field(
    "notes",
    codec.list(note_codec()),
    get: fn(i: Invoice) { i.notes },
  )
  codec.success(Invoice(number:, due_date:, notes:))
}

pub fn main() -> Nil {
  // `with_store(False)` sends `"store": false`, so OpenAI keeps no copy of
  // the response. Files make large bodies: raise the request bound.
  let config =
    openai.new("sk-example")
    |> openai.with_store(False)
    |> openai.config
    |> llm_wire.with_limit(limit.RequestBytes, 50_000_000)

  // A PDF goes in a file part with its name; an image goes in an image part.
  let pdf =
    message.InlineFilePart(
      mime_type: "application/pdf",
      file_name: "invoice.pdf",
      base64_data: "JVBERi0xLjcK",
    )
  let request =
    llm_wire.request("gpt-5", [
      message.UserParts([message.TextPart("Read this invoice"), pdf]),
    ])
    |> llm_wire.with_output("invoice", invoice_codec())
  let call = prepared(config, request)
  let body = llm_wire.request_json(call)
  let assert True = string.contains(body, "\"type\":\"input_file\"")
  let assert True = string.contains(body, "\"store\":false")

  // The model writes `null` for optional fields it has no value for.
  // `Answer.text` is the answer without those members, so the same codec
  // decodes it again later.
  let reply =
    testing.events_for(
      message.OpenAI,
      testing.text(
        "{\"number\":\"A-17\",\"due_date\":null,\"notes\":[{\"text\":\"paid\",\"page\":null}]}",
      ),
    )
  let assert Ok(llm_wire.Answer(output:, text:, ..)) = {
    use client <- scripted([testing.exchange(call, reply)])
    llm_wire.run(client, call)
  }
  let assert Invoice("A-17", None, [Note("paid", None)]) = output
  let assert "{\"number\":\"A-17\",\"notes\":[{\"text\":\"paid\"}]}" = text
  let assert Ok(again) = codec.decode_json(invoice_codec(), text)
  let assert True = again == output

  // An image in a file part is refused before anything is sent.
  let photo = message.InlineFilePart("image/png", "photo.png", "iVBORw0K")
  let assert Error(error.InvalidRequest(error.ImageInFilePart("image/png"))) =
    llm_wire.prepare(
      config,
      llm_wire.request("gpt-5", [message.UserParts([photo])]),
    )
  io.println("invoice " <> output.number <> " read from a PDF")
}
