import gleam/int
import gleam/list
import llm_wire/error
import llm_wire/limit.{type Limit}

/// Every bound of one call, read by the runtime.
pub type Limits {
  Limits(
    request_bytes_limit: Int,
    chunk_bytes_limit: Int,
    line_bytes_limit: Int,
    event_bytes_limit: Int,
    response_body_bytes_limit: Int,
    error_body_bytes_limit: Int,
    queue_count_limit: Int,
    queue_bytes_limit: Int,
    active_blocks_limit: Int,
    text_bytes_per_block_limit: Int,
    total_text_bytes_limit: Int,
    argument_bytes_per_call_limit: Int,
    total_argument_bytes_limit: Int,
    provider_metadata_bytes_limit: Int,
    extension_bytes_limit: Int,
  )
}

pub fn default() -> Limits {
  Limits(
    request_bytes_limit: limit.default(limit.RequestBytes),
    chunk_bytes_limit: limit.default(limit.ChunkBytes),
    line_bytes_limit: limit.default(limit.LineBytes),
    event_bytes_limit: limit.default(limit.EventBytes),
    response_body_bytes_limit: limit.default(limit.ResponseBodyBytes),
    error_body_bytes_limit: limit.default(limit.ErrorBodyBytes),
    queue_count_limit: limit.default(limit.QueueCount),
    queue_bytes_limit: limit.default(limit.QueueBytes),
    active_blocks_limit: limit.default(limit.ActiveBlocks),
    text_bytes_per_block_limit: limit.default(limit.TextBytesPerBlock),
    total_text_bytes_limit: limit.default(limit.TotalTextBytes),
    argument_bytes_per_call_limit: limit.default(limit.ArgumentBytesPerCall),
    total_argument_bytes_limit: limit.default(limit.TotalArgumentBytes),
    provider_metadata_bytes_limit: limit.default(limit.ProviderMetadataBytes),
    extension_bytes_limit: limit.default(limit.ExtensionBytes),
  )
}

pub fn get(limits: Limits, which: Limit) -> Int {
  case which {
    limit.RequestBytes -> limits.request_bytes_limit
    limit.ChunkBytes -> limits.chunk_bytes_limit
    limit.LineBytes -> limits.line_bytes_limit
    limit.EventBytes -> limits.event_bytes_limit
    limit.ResponseBodyBytes -> limits.response_body_bytes_limit
    limit.ErrorBodyBytes -> limits.error_body_bytes_limit
    limit.QueueCount -> limits.queue_count_limit
    limit.QueueBytes -> limits.queue_bytes_limit
    limit.ActiveBlocks -> limits.active_blocks_limit
    limit.TextBytesPerBlock -> limits.text_bytes_per_block_limit
    limit.TotalTextBytes -> limits.total_text_bytes_limit
    limit.ArgumentBytesPerCall -> limits.argument_bytes_per_call_limit
    limit.TotalArgumentBytes -> limits.total_argument_bytes_limit
    limit.ProviderMetadataBytes -> limits.provider_metadata_bytes_limit
    limit.ExtensionBytes -> limits.extension_bytes_limit
  }
}

pub fn set(limits: Limits, which: Limit, value: Int) -> Limits {
  case which {
    limit.RequestBytes -> Limits(..limits, request_bytes_limit: value)
    limit.ChunkBytes -> Limits(..limits, chunk_bytes_limit: value)
    limit.LineBytes -> Limits(..limits, line_bytes_limit: value)
    limit.EventBytes -> Limits(..limits, event_bytes_limit: value)
    limit.ResponseBodyBytes ->
      Limits(..limits, response_body_bytes_limit: value)
    limit.ErrorBodyBytes -> Limits(..limits, error_body_bytes_limit: value)
    limit.QueueCount -> Limits(..limits, queue_count_limit: value)
    limit.QueueBytes -> Limits(..limits, queue_bytes_limit: value)
    limit.ActiveBlocks -> Limits(..limits, active_blocks_limit: value)
    limit.TextBytesPerBlock ->
      Limits(..limits, text_bytes_per_block_limit: value)
    limit.TotalTextBytes -> Limits(..limits, total_text_bytes_limit: value)
    limit.ArgumentBytesPerCall ->
      Limits(..limits, argument_bytes_per_call_limit: value)
    limit.TotalArgumentBytes ->
      Limits(..limits, total_argument_bytes_limit: value)
    limit.ProviderMetadataBytes ->
      Limits(..limits, provider_metadata_bytes_limit: value)
    limit.ExtensionBytes -> Limits(..limits, extension_bytes_limit: value)
  }
}

pub fn validate(limits: Limits) -> Result(Nil, error.PrepareError) {
  case list.find(limit.all(), fn(which) { get(limits, which) <= 0 }) {
    Ok(which) ->
      Error(error.InvalidSetting(
        error.LimitSetting(which),
        "must be positive, got " <> int.to_string(get(limits, which)),
      ))
    Error(Nil) -> Ok(Nil)
  }
}
