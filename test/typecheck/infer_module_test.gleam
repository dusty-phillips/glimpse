import glance
import gleam/option
import gleeunit/should
import glimpse/error
import typecheck/helpers

// TODO: Fix inference and stop skipping this
pub fn module_with_two_functions_skip() {
  let #(inferred_module, _env) =
    helpers.ok_module_typecheck(
      "
      pub fn add(a: Int, b:Int) {a + b}
      pub fn sub(a: Int, b:Int) {a - b}",
    )

  let assert [fun1, fun2] = inferred_module.module.functions

  fun1.definition.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
  fun2.definition.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn proxy_function_error_test() {
  helpers.error_function_typecheck("fn foo(a: Float) -> Float { -a }")
  |> should.equal(error.InvalidType("Float", "Int", "- can only negate Int"))
}
