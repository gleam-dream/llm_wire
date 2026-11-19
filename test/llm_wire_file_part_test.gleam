//// An inline file part: a stored file with its media type and name. Each
//// built-in provider writes a document in its own file form and an image
//// in its own image form, so a caller can send every stored original as one
//// kind of part (ADR 0021).

import gleam/json
import gleam/list
import gleam/string
import gleeunit/should
import llm_wire
import llm_wire/anthropic
import llm_wire/error
import llm_wire/google
import llm_wire/message
import llm_wire/openai

fn pdf() -> message.Content {
  message.InlineFilePart("application/pdf", "report.pdf", "JVBERi0=")
}

fn request(parts: List(message.Content)) -> llm_wire.Request(String) {
  llm_wire.request("model-test", [message.UserParts(parts)])
}

fn body(config: llm_wire.Config, parts: List(message.Content)) -> String {
  let assert Ok(prepared) = llm_wire.prepare(config, request(parts))
  llm_wire.request_json(prepared)
}

fn configs() -> List(llm_wire.Config) {
  [
    openai.new("test-key") |> openai.config,
    anthropic.new("test-key") |> anthropic.config,
    google.new("test-key") |> google.config,
  ]
}

pub fn openai_sends_an_input_file_with_a_data_url_test() {
  body(openai.new("test-key") |> openai.config, [
    message.TextPart("summarize"),
    pdf(),
  ])
  |> string.contains(
    "{\"type\":\"input_file\",\"filename\":\"report.pdf\",\"file_data\":\"data:application/pdf;base64,JVBERi0=\"}",
  )
  |> should.be_true
}

pub fn google_sends_the_file_as_inline_data_test() {
  body(google.new("test-key") |> google.config, [pdf()])
  |> string.contains(
    "{\"inlineData\":{\"mimeType\":\"application/pdf\",\"data\":\"JVBERi0=\"}}",
  )
  |> should.be_true
}

pub fn anthropic_sends_a_pdf_as_a_base64_document_test() {
  body(anthropic.new("test-key") |> anthropic.config, [pdf()])
  |> string.contains(
    "{\"type\":\"document\",\"source\":{\"type\":\"base64\",\"media_type\":\"application/pdf\",\"data\":\"JVBERi0=\"},\"title\":\"report.pdf\"}",
  )
  |> should.be_true
}

pub fn anthropic_refuses_a_file_that_is_not_a_pdf_test() {
  let csv = message.InlineFilePart("text/csv", "rows.csv", "YSxi")
  llm_wire.prepare(
    anthropic.new("test-key") |> anthropic.config,
    request([csv]),
  )
  |> should.equal(
    Error(error.InvalidRequest(error.FileTypeUnsupported("text/csv"))),
  )
}

pub fn openai_and_google_pass_other_file_types_to_the_provider_test() {
  let csv = message.InlineFilePart("text/csv", "rows.csv", "YSxi")
  body(openai.new("test-key") |> openai.config, [csv])
  |> string.contains("\"file_data\":\"data:text/csv;base64,YSxi\"")
  |> should.be_true
  body(google.new("test-key") |> google.config, [csv])
  |> string.contains("\"mimeType\":\"text/csv\"")
  |> should.be_true
}

pub fn a_media_type_is_compared_without_case_or_parameters_test() {
  let upper = message.InlineFilePart("Application/PDF", "a.pdf", "JVBERi0=")
  let assert Ok(_) =
    llm_wire.prepare(
      anthropic.new("test-key") |> anthropic.config,
      request([upper]),
    )
  let image = message.InlineFilePart("IMAGE/JPEG; q=1", "a.jpg", "/9j/")
  body(openai.new("test-key") |> openai.config, [image])
  |> string.contains("\"type\":\"input_image\"")
  |> should.be_true
}

/// An image file part is encoded exactly as an inline image part with the
/// same media type and data; no provider has a field for an image's name.
pub fn every_provider_sends_an_image_file_part_as_an_image_test() {
  let file = message.InlineFilePart("image/png", "photo.png", "iVBO")
  let image = message.InlineImagePart("image/png", "iVBO")
  use config <- list.each(configs())
  let sent = body(config, [message.TextPart("look"), file])
  sent |> should.equal(body(config, [message.TextPart("look"), image]))
  string.contains(sent, "photo.png") |> should.be_false
}

pub fn openai_sends_an_image_file_part_as_an_input_image_test() {
  body(openai.new("test-key") |> openai.config, [
    message.InlineFilePart("image/png", "photo.png", "iVBO"),
  ])
  |> string.contains(
    "{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,iVBO\"}",
  )
  |> should.be_true
}

pub fn anthropic_sends_an_image_file_part_as_an_image_block_test() {
  body(anthropic.new("test-key") |> anthropic.config, [
    message.InlineFilePart("image/jpeg", "scan.jpg", "/9j/"),
  ])
  |> string.contains(
    "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/jpeg\",\"data\":\"/9j/\"}}",
  )
  |> should.be_true
}

pub fn the_refusal_is_described_test() {
  error.describe_prepare_error(
    error.InvalidRequest(error.FileTypeUnsupported("text/csv")),
  )
  |> string.contains("text/csv")
  |> should.be_true
}

pub fn a_file_part_round_trips_through_the_message_codec_test() {
  let stored = message.UserParts([message.TextPart("read"), pdf()])
  let encoded = json.to_string(message.to_json(stored))
  encoded
  |> string.contains(
    "{\"type\":\"inline_file\",\"mime_type\":\"application/pdf\",\"file_name\":\"report.pdf\",\"data\":\"JVBERi0=\"}",
  )
  |> should.be_true
  json.parse(encoded, message.decoder()) |> should.equal(Ok(stored))
}
