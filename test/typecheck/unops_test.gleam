import glance
import gleam/option
import glimpse/error
import typecheck/helpers

pub fn negate_int_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { -5 }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn negate_int_param_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo(a: Int) -> Int { -a }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(18, 21), "Int", option.None, []),
    )
}

pub fn negate_int_invalid_test() {
  assert helpers.error_function_typecheck("fn foo(a: Float) -> Float { -a }")
    == error.InvalidType("Float", "Int", "- can only negate Int")
}

pub fn negate_bool_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Bool { !True }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 16), "Bool", option.None, []),
    )
}

pub fn negate_bool_param_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo(a: Bool) -> Bool { !a }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(19, 23), "Bool", option.None, []),
    )
}

pub fn negate_bool_invalid_test() {
  assert helpers.error_function_typecheck("fn foo(a: Float) -> Bool { !a }")
    == error.InvalidType("Float", "Bool", "! can only negate Bool")
}
