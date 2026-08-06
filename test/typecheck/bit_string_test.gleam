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

pub fn double_variable_assignment_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { let assert <<a as b>> = <<>> a }",
    )
    == error.DoubleVariableAssignment
}
