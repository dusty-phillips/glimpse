import glance
import gleam/option
import glimpse/error
import typecheck/helpers

const unknown_span = glance.Span(-1, -1)

// TODO: Fix inference and stop skipping this
pub fn module_with_two_functions_skip() {
  let #(inferred_module, _env) =
    helpers.ok_module_typecheck(
      "
      pub fn add(a: Int, b:Int) {a + b}
      pub fn sub(a: Int, b:Int) {a - b}",
    )

  let assert [fun1, fun2] = inferred_module.module.functions

  assert fun1.definition.return
    == option.Some(glance.NamedType(unknown_span, "Int", option.None, []))
  assert fun2.definition.return
    == option.Some(glance.NamedType(unknown_span, "Int", option.None, []))
}

pub fn proxy_function_error_test() {
  assert helpers.error_function_typecheck("fn foo(a: Float) -> Float { -a }")
    == error.InvalidType("Float", "Int", "- can only negate Int")
}
