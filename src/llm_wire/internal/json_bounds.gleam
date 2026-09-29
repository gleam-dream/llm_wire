import gleam/bit_array

pub fn check_depth(raw: String) -> Result(Nil, Nil) {
  scan_depth(bit_array.from_string(raw), 0, False, False)
}

fn scan_depth(
  raw: BitArray,
  depth: Int,
  quoted: Bool,
  escaped: Bool,
) -> Result(Nil, Nil) {
  case depth > 64 {
    True -> Error(Nil)
    False ->
      case raw {
        <<>> -> Ok(Nil)
        <<char, rest:bytes>> ->
          case quoted, escaped, char {
            True, True, _ -> scan_depth(rest, depth, True, False)
            True, False, 92 -> scan_depth(rest, depth, True, True)
            _, _, 34 -> scan_depth(rest, depth, !quoted, False)
            False, _, 123 | False, _, 91 ->
              scan_depth(rest, depth + 1, False, False)
            False, _, 125 | False, _, 93 ->
              scan_depth(rest, depth - 1, False, False)
            _, _, _ -> scan_depth(rest, depth, quoted, False)
          }
        _ -> Ok(Nil)
      }
  }
}
