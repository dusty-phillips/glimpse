import glance
import gleam/option
import gleeunit/should
import glimpse/error
import typecheck/helpers

pub fn assign_let_returned_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> Int { let x = 5 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn assign_let_used_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo() -> Int {
    let x = 5
    x + 2}",
    )

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn assign_let_with_type() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo() -> Int {
    let x: Int = 5
    x + 2}",
    )

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn assign_let_with_binop() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo() -> Int {
    let x = 5
    let y: Int = 5 + a
    y + 2}",
    )

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn assign_let_incorrect_type_test() {
  helpers.error_function_typecheck(
    "fn foo() {
    let x: String = 5
  }",
  )
  |> should.equal(error.InvalidType("Int", "String", "during assignment of x"))
}

pub fn assign_let_value_error_test() {
  helpers.error_function_typecheck(
    "fn foo() {
    let x: String = a
  }",
  )
  |> should.equal(error.InvalidName("a"))
}
