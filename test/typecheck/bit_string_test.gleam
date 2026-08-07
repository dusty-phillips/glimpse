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

pub fn double_variable_assignment_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { let assert <<a as b>> = <<>> a }",
    )
    == error.DoubleVariableAssignment
}
