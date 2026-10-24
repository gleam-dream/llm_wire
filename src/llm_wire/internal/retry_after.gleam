import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/duration.{type Duration}
import gleam/time/timestamp

/// The delay a `Retry-After` header asks for, read on receipt: delay
/// seconds, or an HTTP date measured from now. A date in the past is a zero
/// delay; an unreadable value is `None`.
pub fn from_headers(headers: List(#(String, String))) -> Option(Duration) {
  case
    list.find(headers, fn(header) {
      string.lowercase(header.0) == "retry-after"
    })
  {
    Ok(#(_, value)) -> parse(value, timestamp.system_time())
    Error(Nil) -> None
  }
}

pub fn parse(value: String, now: timestamp.Timestamp) -> Option(Duration) {
  let value = string.trim(value)
  case int.parse(value) {
    Ok(seconds) if seconds >= 0 -> Some(duration.seconds(seconds))
    Ok(_) -> None
    Error(Nil) ->
      case timestamp.parse_http_date(value) {
        Ok(at) -> {
          let delay = timestamp.difference(now, at)
          case duration.to_seconds_and_nanoseconds(delay) {
            #(seconds, _) if seconds < 0 -> Some(duration.seconds(0))
            _ -> Some(delay)
          }
        }
        Error(Nil) -> None
      }
  }
}
