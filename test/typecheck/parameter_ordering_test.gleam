import glance
import glexer.{type Position, Position}
import glimpse/error
import typecheck/helpers

pub fn duplicate_anon_function_arguments_test() {
  assert helpers.error_function_typecheck("pub fn main() { fn(x, x) { Nil } }")
    == error.DuplicateArgumentName("x")
}

pub fn duplicate_labelled_parameters_in_signature_test() {
  assert helpers.error_module_typecheck(
      "pub fn main(name a: Int, name b: Int) { Nil }
  fn bar() { main(name: 1, name: 2) }",
    )
    == error.DuplicateArgumentName("name")
}

pub fn unlabelled_argument_after_labelled_argument_test() {
  assert glance.module("pub fn main(wibble wibber, wobber) { Nil }")
    == Error(glance.UnlabelledAfterLabelled)
}

pub fn positional_argument_after_labelled_test() {
  let actual =
    helpers.error_module_typecheck(
      "pub type X {
    X(a: Int, b: Int)
  }
  pub fn main() {
    X(b: 1, 2)
  }",
    )
  assert actual == error.PositionalArgumentAfterLabelled
}

pub fn distinct_anon_function_parameter_names_test() {
  helpers.ok_function_typecheck("pub fn main() { fn(x, y) { x } }")
}

pub fn dangling_external_attribute_is_rejected_test() {
  let assert Error(glance.UnexpectedAttributeEnd(Position(17))) =
    glance.module(
      "pub type Audio
  @external(javascript, \"../../audio_ffi.mjs\", \"play\")",
    )
}

pub fn labelled_parameter_followed_by_unlabelled_is_rejected_test() {
  assert glance.module("pub fn f(from x: Int, y: Int) -> Int { 0 }")
    == Error(glance.UnlabelledAfterLabelled)
}

pub fn unlabelled_then_labelled_parameter_is_fine_test() {
  let assert Ok(_) = glance.module("pub fn f(x: Int, from y: Int) -> Int { 0 }")
}

pub fn all_labelled_parameters_are_fine_test() {
  let assert Ok(_) =
    glance.module("pub fn f(from x: Int, to y: Int) -> Int { 0 }")
}
