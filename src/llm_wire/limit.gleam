//// Names every byte and count bound that LLM Wire applies to a call.
////
//// Set a bound with `llm_wire.with_limit`; a call that exceeds it fails with
//// `error.LimitExceeded` naming the same `Limit`, so the error says which
//// setter raises it:
////
//// ```gleam
//// import llm_wire
//// import llm_wire/limit
////
//// let config =
////   openai.new(key) |> openai.config
////   |> llm_wire.with_limit(limit.TotalTextBytes, 8_388_608)
//// ```
////
//// | Limit | Default | Bounds |
//// | --- | --- | --- |
//// | `RequestBytes` | 1 MiB | the encoded request body |
//// | `ChunkBytes` | 64 KiB | one transport chunk |
//// | `LineBytes` | 1 MiB | one SSE line |
//// | `EventBytes` | 1 MiB | one SSE event |
//// | `ResponseBodyBytes` | 8 MiB | the whole streamed response |
//// | `ErrorBodyBytes` | 64 KiB | the body of a non-200 response |
//// | `QueueCount` | 500 | progress items waiting for `next` |
//// | `QueueBytes` | 2 MiB | bytes of progress waiting for `next` |
//// | `ActiveBlocks` | 64 | text, reasoning and tool blocks open at once |
//// | `TextBytesPerBlock` | 1 MiB | one text, refusal or reasoning block |
//// | `TotalTextBytes` | 4 MiB | all text of one response |
//// | `ArgumentBytesPerCall` | 1 MiB | one tool call's arguments |
//// | `TotalArgumentBytes` | 4 MiB | all tool-call arguments of one response |
//// | `ProviderMetadataBytes` | 1 MiB | ids, signatures and replay data |
//// | `ExtensionBytes` | 16 KiB | the name of an unrecognized provider event |
////
//// Every limit must be positive; `llm_wire.prepare` rejects any other value
//// with `error.InvalidSetting(error.LimitSetting(limit), ..)`.

/// One bound of a call. Never gains a variant without a new setter value.
pub type Limit {
  RequestBytes
  ChunkBytes
  LineBytes
  EventBytes
  ResponseBodyBytes
  ErrorBodyBytes
  QueueCount
  QueueBytes
  ActiveBlocks
  TextBytesPerBlock
  TotalTextBytes
  ArgumentBytesPerCall
  TotalArgumentBytes
  ProviderMetadataBytes
  ExtensionBytes
}

/// Every limit, in the order of the table above.
pub fn all() -> List(Limit) {
  [
    RequestBytes,
    ChunkBytes,
    LineBytes,
    EventBytes,
    ResponseBodyBytes,
    ErrorBodyBytes,
    QueueCount,
    QueueBytes,
    ActiveBlocks,
    TextBytesPerBlock,
    TotalTextBytes,
    ArgumentBytesPerCall,
    TotalArgumentBytes,
    ProviderMetadataBytes,
    ExtensionBytes,
  ]
}

/// A stable snake_case name for logs and stored records, such as
/// `"total_text_bytes"`.
pub fn name(limit: Limit) -> String {
  case limit {
    RequestBytes -> "request_bytes"
    ChunkBytes -> "chunk_bytes"
    LineBytes -> "line_bytes"
    EventBytes -> "event_bytes"
    ResponseBodyBytes -> "response_body_bytes"
    ErrorBodyBytes -> "error_body_bytes"
    QueueCount -> "queue_count"
    QueueBytes -> "queue_bytes"
    ActiveBlocks -> "active_blocks"
    TextBytesPerBlock -> "text_bytes_per_block"
    TotalTextBytes -> "total_text_bytes"
    ArgumentBytesPerCall -> "argument_bytes_per_call"
    TotalArgumentBytes -> "total_argument_bytes"
    ProviderMetadataBytes -> "provider_metadata_bytes"
    ExtensionBytes -> "extension_bytes"
  }
}

/// The default value of a limit.
pub fn default(limit: Limit) -> Int {
  case limit {
    RequestBytes -> 1_048_576
    ChunkBytes -> 65_536
    LineBytes -> 1_048_576
    EventBytes -> 1_048_576
    ResponseBodyBytes -> 8_388_608
    ErrorBodyBytes -> 65_536
    QueueCount -> 500
    QueueBytes -> 2_097_152
    ActiveBlocks -> 64
    TextBytesPerBlock -> 1_048_576
    TotalTextBytes -> 4_194_304
    ArgumentBytesPerCall -> 1_048_576
    TotalArgumentBytes -> 4_194_304
    ProviderMetadataBytes -> 1_048_576
    ExtensionBytes -> 16_384
  }
}
