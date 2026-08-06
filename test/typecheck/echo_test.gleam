import glance
import gleam/option
import glimpse/error
import typecheck/helpers

pub fn echo_undefined_variable_is_typechecked_test() {
  assert helpers.error_function_typecheck("pub fn main() { echo undefined }")
    == error.InvalidName("undefined")
}

pub fn echo_has_same_type_as_printed_expression_test() {
  let function =
    helpers.ok_function_typecheck("pub fn main() -> Int { echo 1 }")
  assert function.return
    == option.Some(
      glance.NamedType(glance.Span(17, 20), "Int", option.None, []),
    )
}

pub fn echo_in_pipeline_acts_as_identity_test() {
  let function =
    helpers.ok_function_typecheck(
      "
  pub fn main() {
    [1, 2, 3]
    |> echo
  }",
    )
  assert function.return
    == option.Some(
      glance.NamedType(glance.Span(-1, -1), "List", option.None, [
        glance.NamedType(glance.Span(-1, -1), "Int", option.None, []),
      ]),
    )
}
