import glance
import gleam/option
import gleeunit/should
import glimpse/error
import typecheck/helpers

pub fn negate_int_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { -5 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn negate_int_param_test() {
  let function_out = helpers.ok_function_typecheck("fn foo(a: Int) -> Int { -a }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn negate_int_invalid_test() {
  helpers.error_function_typecheck("fn foo(a: Float) -> Float { -a }")
  |> should.equal(error.InvalidType("Float", "Int", "- can only negate Int"))
}

pub fn negate_bool_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Bool { !True }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Bool", option.None, [])))
}

pub fn negate_bool_param_test() {
  let function_out = helpers.ok_function_typecheck("fn foo(a: Bool) -> Bool { !a }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Bool", option.None, [])))
}

pub fn negate_bool_invalid_test() {
  helpers.error_function_typecheck("fn foo(a: Float) -> Bool { !a }")
  |> should.equal(error.InvalidType("Float", "Bool", "! can only negate Bool"))
}
