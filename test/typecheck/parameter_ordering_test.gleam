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
  assert helpers.error_module_typecheck(
      "pub fn main(wibble wibber, wobber) { Nil }",
    )
    == error.UnlabelledArgumentAfterLabelled
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
