import glance
import gleam/option
import gleeunit/should
import glimpse/error
import typecheck/helpers

pub fn int_param_test() {
  let function_out = helpers.ok_typecheck("fn foo(a: Int) -> Int { a }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn int_param_operation_test() {
  let function_out =
    helpers.ok_typecheck("fn add(a: Int, b: Int) -> Int { a + b }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn float_param_test() {
  let function_out = helpers.ok_typecheck("fn foo(a: Float) -> Float { a }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Float", option.None, [])))
}

pub fn string_param_test() {
  let function_out = helpers.ok_typecheck("fn foo(a: String) -> String { a }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("String", option.None, [])))
}

pub fn incorrect_param_return_fails() {
  helpers.error_typecheck("fn foo(a: String) -> Nil { a }")
  |> should.equal(error.InvalidReturnType("foo", "String", "Nil"))
}
