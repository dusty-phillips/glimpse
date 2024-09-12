import glance
import gleam/option
import gleeunit/should
import glimpse/error
import typecheck/helpers

pub fn return_nil_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Nil { Nil }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Nil", option.None, [])))
}

pub fn infer_nil_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Nil", option.None, [])))
}

pub fn not_nil_error_test() {
  helpers.error_function_typecheck("fn foo() -> Nil { 5 }")
  |> should.equal(error.InvalidReturnType("foo", "Int", "Nil"))
}

pub fn return_int_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { 5 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn infer_int_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { 5 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn not_int_error_test() {
  helpers.error_function_typecheck("fn foo() -> Int { Nil }")
  |> should.equal(error.InvalidReturnType("foo", "Nil", "Int"))
}

pub fn return_float_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Float { 5.0 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Float", option.None, [])))
}

pub fn infer_float_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { 5.0 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Float", option.None, [])))
}

pub fn not_float_error_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 5 }")
  |> should.equal(error.InvalidReturnType("foo", "Int", "Float"))
}

pub fn return_string_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> String { \"hello\" }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("String", option.None, [])))
}

pub fn infer_string_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { \"hello\" }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("String", option.None, [])))
}

pub fn not_string_error_test() {
  helpers.error_function_typecheck("fn foo() -> String { 5 }")
  |> should.equal(error.InvalidReturnType("foo", "Int", "String"))
}

pub fn return_true_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Bool { True }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Bool", option.None, [])))
}

pub fn return_false_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Bool { False }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Bool", option.None, [])))
}

pub fn infer_bool_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { True }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Bool", option.None, [])))
}

pub fn not_bool_error_test() {
  helpers.error_function_typecheck("fn foo() -> Bool { 5 }")
  |> should.equal(error.InvalidReturnType("foo", "Int", "Bool"))
}
