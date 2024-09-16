import gleam/list
import gleeunit/should
import typecheck/helpers

pub fn simple_nil_function_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn foo() -> Nil { Nil }
    fn bar() -> Nil { foo() } ",
    )

  module.module.functions
  |> list.length
  |> should.equal(2)
}
