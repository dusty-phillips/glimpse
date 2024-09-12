import glance
import gleam/option
import gleeunit/should
import glimpse/error
import typecheck/helpers

pub fn single_variant_custom_type() {
  let function_out = helpers.ok_function_typecheck("pub type Foo {Foo()}")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}
