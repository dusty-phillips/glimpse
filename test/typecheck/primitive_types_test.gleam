import glance
import gleam/option
import glimpse/error
import typecheck/helpers

const unknown_span = glance.Span(-1, -1)

pub fn return_nil_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Nil { Nil }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Nil", option.None, []),
    )
}

pub fn infer_nil_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { }")

  assert function_out.return
    == option.Some(glance.NamedType(unknown_span, "Nil", option.None, []))
}

pub fn not_nil_error_test() {
  assert helpers.error_function_typecheck("fn foo() -> Nil { 5 }")
    == error.InvalidReturnType("foo", "Int", "Nil")
}

pub fn return_int_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { 5 }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn infer_int_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { 5 }")

  assert function_out.return
    == option.Some(glance.NamedType(unknown_span, "Int", option.None, []))
}

pub fn not_int_error_test() {
  assert helpers.error_function_typecheck("fn foo() -> Int { Nil }")
    == error.InvalidReturnType("foo", "Nil", "Int")
}

pub fn return_float_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Float { 5.0 }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 17), "Float", option.None, []),
    )
}

pub fn infer_float_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { 5.0 }")

  assert function_out.return
    == option.Some(glance.NamedType(unknown_span, "Float", option.None, []))
}

pub fn not_float_error_test() {
  assert helpers.error_function_typecheck("fn foo() -> Float { 5 }")
    == error.InvalidReturnType("foo", "Int", "Float")
}

pub fn return_string_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> String { \"hello\" }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 18), "String", option.None, []),
    )
}

pub fn infer_string_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { \"hello\" }")

  assert function_out.return
    == option.Some(glance.NamedType(unknown_span, "String", option.None, []))
}

pub fn not_string_error_test() {
  assert helpers.error_function_typecheck("fn foo() -> String { 5 }")
    == error.InvalidReturnType("foo", "Int", "String")
}

pub fn return_true_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Bool { True }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 16), "Bool", option.None, []),
    )
}

pub fn return_false_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Bool { False }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 16), "Bool", option.None, []),
    )
}

pub fn infer_bool_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { True }")

  assert function_out.return
    == option.Some(glance.NamedType(unknown_span, "Bool", option.None, []))
}

pub fn not_bool_error_test() {
  assert helpers.error_function_typecheck("fn foo() -> Bool { 5 }")
    == error.InvalidReturnType("foo", "Int", "Bool")
}
