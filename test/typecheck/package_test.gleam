import glance
import gleam/dict
import gleam/list
import gleam/option
import gleeunit/should
import typecheck/assertions
import typecheck/helpers

pub fn typecheck_single_module_package_test() {
  let package =
    helpers.ok_package_check("main_module", fn(_) {
      Ok("pub fn main() -> Nil {}")
    })

  let module =
    package.modules
    |> dict.get("main_module")
    |> should.be_ok

  module.module.functions
  |> assertions.should_have_list_length(1)
  |> list.first
  |> should.be_ok
  |> should.equal(glance.Definition(
    [],
    glance.Function(
      "main",
      glance.Public,
      [],
      option.Some(glance.NamedType("Nil", option.None, [])),
      [],
      glance.Span(0, 23),
    ),
  ))
}
