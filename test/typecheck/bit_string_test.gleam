import glimpse/error
import typecheck/helpers

pub fn size_must_be_int_test() {
  assert helpers.error_module_typecheck(
      "fn x() { \"test\" }
pub fn main() { let a = <<1:size(x())>> a }",
    )
    == error.InvalidBitStringSegment("size")
}

pub fn conflicting_sizes_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { let x = <<1:8-size(5)>> x }",
    )
    == error.InvalidBitStringSegment("size")
}

pub fn negative_literal_size_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { let assert <<1:size(-1)>> = <<>> 1 }",
    )
    == error.InvalidBitStringSegment("size")
}

pub fn valid_bit_string_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn main() {
  let x = <<1:8, 2:16>>
  x
}",
  )
}

pub fn string_literal_segment_needs_no_option_test() {
  // A bare String literal defaults to its own family, but an integer size
  // makes the segment an `Int`, which a String cannot be.
  helpers.ok_module_typecheck("pub fn main() { <<\"x\">> }")
  assert helpers.error_module_typecheck("pub fn main() { <<\"x\":8>> }")
    == error.InvalidType("String", "Int", "in bit string segment")
}

pub fn float_literal_segment_needs_no_option_test() {
  helpers.ok_module_typecheck("pub fn main() { <<1.5>> }")
  assert helpers.error_module_typecheck("pub fn main() { <<1.5:8>> }")
    == error.InvalidType("Float", "Int", "in bit string segment")
}

pub fn variable_segment_requires_option_test() {
  // A non-literal String/Float segment must declare its family with an
  // option; an unadorned variable segment is an `Int`.
  assert helpers.error_module_typecheck(
      "pub fn f(s: String) -> BitArray { <<s>> }",
    )
    == error.InvalidType("String", "Int", "in bit string segment")
}

pub fn pattern_bits_not_last_is_rejected_test() {
  // A bare `bits`/`bytes` pattern segment matches the rest of the bit array,
  // so it is only valid as the final segment.
  assert helpers.error_module_typecheck(
      "pub fn f(bits: BitArray) -> Bool {
      case bits {
        <<_:bits, rest:bytes>> -> True
        _ -> False
      }
    }",
    )
    == error.InvalidBitStringSegment("bits")
}

pub fn pattern_utf_on_variable_is_rejected_test() {
  // A utf segment cannot bind a plain variable; use `_` or a literal.
  assert helpers.error_module_typecheck(
      "pub fn f(bits: BitArray) -> Bool {
      case bits {
        <<x:utf8, rest:bytes>> -> True
        _ -> False
      }
    }",
    )
    == error.InvalidBitStringSegment("utf8")
}

pub fn pattern_sized_bits_anywhere_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn f(bits: BitArray) -> Bool {
      case bits {
        <<pref:bits-size(8), _:bits>> -> True
        _ -> False
      }
    }",
  )
}

pub fn double_variable_assignment_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { let assert <<a as b>> = <<>> a }",
    )
    == error.DoubleVariableAssignment
}

pub fn signed_option_in_expression_is_rejected_test() {
  // `signed`/`unsigned` are only valid in bit-array patterns; in an
  // expression the segment's bytes are already being built, so the real
  // compiler rejects the option with "Invalid bit array segment".
  assert helpers.error_module_typecheck(
      "pub fn f(n: Int) -> BitArray { <<n:signed>> }",
    )
    == error.InvalidBitStringSegment("signed")
  assert helpers.error_module_typecheck(
      "pub fn f(n: Int) -> BitArray { <<n:unsigned>> }",
    )
    == error.InvalidBitStringSegment("signed")
}

pub fn bytes_option_in_expression_is_rejected_test() {
  // A `bytes` (or `binary`, which glance lexes as `bytes`) type option is only
  // valid in bit-array *patterns*; in an expression the segment is already a
  // BitArray value, so the real compiler rejects the option with
  // "This option is only allowed in BitArray patterns".
  assert helpers.error_module_typecheck(
      "pub fn f(b: BitArray) -> BitArray { <<b:bytes>> }",
    )
    == error.InvalidBitStringSegment("signed")
  assert helpers.error_module_typecheck(
      "pub fn f(b: BitArray) -> BitArray { <<b:binary>> }",
    )
    == error.InvalidBitStringSegment("signed")
}

pub fn bytes_option_in_pattern_is_fine_test() {
  // In a pattern a `bytes` type option selects the BitArray family, matching
  // the segment value (a whole BitArray), which the real compiler accepts.
  helpers.ok_module_typecheck(
    "pub fn f(b: BitArray) -> Int {
    case b {
      <<x:bytes>> -> 1
      _ -> 0
    }
  }",
  )
}

pub fn unit_without_size_is_rejected_test() {
  // A `unit` must always be accompanied by an explicit `size`; on its own the
  // segment width is underdetermined and the real compiler rejects it, in both
  // expressions and patterns.
  assert helpers.error_module_typecheck(
      "pub fn f(n: Int) -> BitArray { <<n:unit(8)>> }",
    )
    == error.InvalidBitStringSegment("signed")
  assert helpers.error_module_typecheck(
      "pub fn f(bits: BitArray) -> Bool {
      case bits {
        <<_:unit(8)>> -> True
        _ -> False
      }
    }",
    )
    == error.InvalidBitStringSegment("unit")
}

pub fn signed_in_pattern_is_fine_test() {
  // In a pattern `signed`/`unsigned` are valid segment options.
  helpers.ok_module_typecheck(
    "pub fn f(bits: BitArray) -> Bool {
      case bits {
        <<n:signed-size(8), _:bits>> -> True
        _ -> False
      }
    }",
  )
}

pub fn unit_with_size_is_fine_test() {
  // `unit` combined with an explicit `size` is valid in both expressions and
  // patterns.
  helpers.ok_module_typecheck(
    "pub fn f(n: Int) -> BitArray { <<n:size(16)-unit(8)>> }",
  )
  helpers.ok_module_typecheck(
    "pub fn f(bits: BitArray) -> Bool {
      case bits {
        <<_:unit(8)-size(16)>> -> True
        _ -> False
      }
    }",
  )
}

pub fn size_variable_in_pattern_is_fine_test() {
  // A size expression may reference a variable bound elsewhere in the module,
  // exercising the bit-array size-variable checks.
  helpers.ok_module_typecheck(
    "pub fn f(bits: BitArray, n: Int) -> Bool {
      case bits {
        <<value:size(n), _:bits>> -> True
        _ -> False
      }
    }",
  )
}

pub fn size_variable_must_be_int_test() {
  assert helpers.error_module_typecheck(
      "pub fn f(bits: BitArray, n: String) -> Bool {
      case bits {
        <<value:size(n), _:bits>> -> True
        _ -> False
      }
    }",
    )
    == error.InvalidType("String", "Int", "size variables must be Int")
}

pub fn size_variable_must_exist_test() {
  assert helpers.error_module_typecheck(
      "pub fn f(bits: BitArray) -> Bool {
      case bits {
        <<value:size(n), _:bits>> -> True
        _ -> False
      }
    }",
    )
    == error.InvalidName("n")
}

pub fn size_variable_referencing_earlier_segment_is_fine_test() {
  // A size expression may reference a variable bound by an earlier segment in
  // the same bit string (`<<length:32, value:bytes-size(length)>>`), as in the
  // squirrel postgres protocol decoder.
  helpers.ok_module_typecheck(
    "pub fn f(packet: BitArray) -> Int {
      case packet {
        <<length:32, value:bytes-size(length), rest:bytes>> -> length
        _ -> 0
      }
    }",
  )
}

pub fn size_variable_referencing_earlier_segment_typechecking_test() {
  // The referenced variable must be bound in the current bit string or in
  // scope; a size referencing a later, not-yet-bound segment is an error.
  assert helpers.error_module_typecheck(
      "pub fn f(packet: BitArray) -> Int {
      case packet {
        <<value:bytes-size(length), length:32, rest:bytes>> -> length
        _ -> 0
      }
    }",
    )
    == error.InvalidName("length")
}
