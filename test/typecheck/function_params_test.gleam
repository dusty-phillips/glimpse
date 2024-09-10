import glance
import gleam/option
import gleeunit/should
import typecheck/helpers

pub fn int_param_test() {
  let function_out = helpers.ok_typecheck("fn foo(a: Int) -> Int { a }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}
