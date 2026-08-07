import glance
import gleam/list
import gleam/option
import glimpse/internal/typecheck/types

/// The type a bit-string segment with the given options matches, mirroring how
/// the real compiler classifies a segment: a utf option makes it a String, a
/// codepoint option a `UtfCodepoint`, byte/bits options a BitArray, a float a
/// Float, and anything else an Int. The option type parameter is polymorphic
/// because expression segments and pattern segments carry different payloads.
pub fn segment_type(
  options: List(glance.BitStringSegmentOption(a)),
) -> types.Type {
  case list.any(options, is_utf_option) {
    True -> types.StringType
    False ->
      case list.any(options, is_codepoint_option) {
        True -> types.CustomType("prelude", "UtfCodepoint", [], option.None)
        False ->
          case list.any(options, is_bytes_option) {
            True -> types.BitArrayType
            False ->
              case list.any(options, is_float_option) {
                True -> types.FloatType
                False -> types.IntType
              }
          }
      }
  }
}

pub fn is_utf_option(option: glance.BitStringSegmentOption(a)) -> Bool {
  case option {
    glance.Utf8Option | glance.Utf16Option | glance.Utf32Option -> True
    _ -> False
  }
}

fn is_codepoint_option(option: glance.BitStringSegmentOption(a)) -> Bool {
  case option {
    glance.Utf8CodepointOption
    | glance.Utf16CodepointOption
    | glance.Utf32CodepointOption -> True
    _ -> False
  }
}

fn is_bytes_option(option: glance.BitStringSegmentOption(a)) -> Bool {
  case option {
    glance.BytesOption | glance.BitsOption -> True
    _ -> False
  }
}

fn is_float_option(option: glance.BitStringSegmentOption(a)) -> Bool {
  case option {
    glance.FloatOption -> True
    _ -> False
  }
}
