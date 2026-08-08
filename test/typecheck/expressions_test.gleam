import glance
import gleam/dict
import gleam/list
import gleam/option
import glimpse/error
import glimpse/internal/typecheck/types
import typecheck/helpers

const unknown_span = glance.Span(-1, -1)

pub fn todo_return_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { todo }")

  assert function_out.return
    == option.Some(glance.VariableType(unknown_span, "todo"))
}

pub fn panic_return_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { panic }")

  assert function_out.return
    == option.Some(glance.VariableType(unknown_span, "todo"))
}

pub fn tuple_return_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> #(Int, String) { #(1, \"a\") }")

  assert function_out.return
    == option.Some(
      glance.TupleType(glance.Span(12, 26), [
        glance.NamedType(glance.Span(14, 17), "Int", option.None, []),
        glance.NamedType(glance.Span(19, 25), "String", option.None, []),
      ]),
    )
}

pub fn tuple_index_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> Int { #(1, \"a\").0 }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn tuple_index_second_element_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> String { #(1, \"a\").1 }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 18), "String", option.None, []),
    )
}

pub fn tuple_index_out_of_range_test() {
  assert helpers.error_function_typecheck("fn foo() -> Int { #(1, \"a\").2 }")
    == error.UnexpectedType(
      "(Int, String)",
      "a tuple with an element at index 2",
    )
}

pub fn tuple_index_on_non_tuple_test() {
  assert helpers.error_function_typecheck("fn foo(x: Int) -> Int { x.0 }")
    == error.UnexpectedType("Int", "a tuple with an element at index 0")
}

pub fn tuple_index_on_unknown_type_test() {
  let got =
    helpers.error_function_typecheck(
      "fn foo() {
    let z = todo
    fn(x) { x.2 }(z)
  }",
    )
  let message = case got {
    error.UnexpectedType(_, message) -> message
    _ -> "unexpected error"
  }
  assert "a tuple with an element at index 2" == message
}

pub fn list_infer_return_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { [1, 2, 3] }")

  assert function_out.return
    == option.Some(
      glance.NamedType(unknown_span, "List", option.None, [
        glance.NamedType(unknown_span, "Int", option.None, []),
      ]),
    )
}

pub fn mixed_list_error_test() {
  assert helpers.error_function_typecheck("fn foo() { [1, \"a\"] }")
    == error.InvalidType("Int", "String", "in type mismatch")
}

pub fn bit_array_return_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> BitArray { <<1, 2>> }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 20), "BitArray", option.None, []),
    )
}

pub fn bit_string_return_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> BitArray { <<1>> }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 20), "BitArray", option.None, []),
    )
}

pub fn bit_string_utf8_segment_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> BitArray { <<\"abc\":utf8>> }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 20), "BitArray", option.None, []),
    )
}

pub fn anonymous_fn_return_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() { fn(x: Int) { x + 1 } }")

  assert function_out.return
    == option.Some(glance.FunctionType(
      unknown_span,
      [glance.NamedType(unknown_span, "Int", option.None, [])],
      glance.NamedType(unknown_span, "Int", option.None, []),
    ))
}

pub fn anonymous_fn_missing_annotation_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { fn(x) { x } }")

  // The anonymous function's parameter should be inferred as a generic type variable
  assert function_out.return
    == option.Some(glance.FunctionType(
      unknown_span,
      [glance.VariableType(unknown_span, "a")],
      glance.VariableType(unknown_span, "a"),
    ))
}

pub fn record_update_test() {
  helpers.ok_module_typecheck(
    "pub type Person {
    Person(name: String, age: Int)
  }
  fn update(p: Person) -> Person {
    Person(..p, age: 30)
  }",
  )
}

pub fn record_update_wrong_field_type_test() {
  assert helpers.error_module_typecheck(
      "pub type Person {
    Person(name: String, age: Int)
  }
  fn update(p: Person) -> Person {
    Person(..p, age: \"thirty\")
  }",
    )
    == error.InvalidType("String", "Int", "in record update of field age")
}

pub fn parametric_record_update_test() {
  helpers.ok_module_typecheck(
    "type Box(a) { Box(value: a) }
  fn update(b: Box(Int)) -> Box(Int) {
    Box(..b, value: 30)
  }",
  )
}

pub fn parametric_record_update_wrong_field_type_test() {
  assert helpers.error_module_typecheck(
      "type Box(a) { Box(value: a) }
  fn update(b: Box(Int)) -> Box(Int) {
    Box(..b, value: \"thirty\")
  }",
    )
    == error.InvalidReturnType(
      "update",
      "main_module.Box(String)",
      "main_module.Box(Int)",
    )
}

pub fn assert_bool_returns_nil_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { assert 1 == 1 }")

  assert function_out.return
    == option.Some(glance.NamedType(unknown_span, "Nil", option.None, []))
}

pub fn assert_non_bool_error_test() {
  assert helpers.error_function_typecheck("fn foo() { assert 5 }")
    == error.InvalidType("Int", "Bool", "the assert statement requires a Bool")
}

pub fn block_expression_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { { 1 } }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn block_last_statement_type_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo() -> Int {
    1
    2}",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn case_multiple_clauses_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> String { case x { 1 -> \"one\" _ -> \"other\" } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(18, 24), "String", option.None, []),
    )
}

pub fn case_guard_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> Int { case x { 1 if x == 1 -> 1 _ -> 0 } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(18, 21), "Int", option.None, []),
    )
}

pub fn case_invalid_guard_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { 1 if x + 1 -> 1 _ -> 0 } }",
    )
    == error.InvalidGuard("Int")
}

pub fn guard_function_call_rejected_test() {
  assert helpers.error_module_typecheck(
      "fn pos(x: Int) -> Bool { x > 0 } fn foo(x: Int) -> Int { case x { y if pos(y) -> 0 _ -> 1 } }",
    )
    == error.InvalidGuardExpression
}

pub fn guard_pipeline_rejected_test() {
  assert helpers.error_module_typecheck(
      "fn pos(x: Int) -> Bool { x > 0 } fn foo(x: Int) -> Int { case x { y if y |> pos -> 0 _ -> 1 } }",
    )
    == error.InvalidGuardExpression
}

pub fn guard_case_expression_rejected_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { y if case y { 1 -> True _ -> False } -> 0 _ -> 1 } }",
    )
    == error.InvalidGuardExpression
}

pub fn guard_panic_rejected_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { y if panic -> 0 _ -> 1 } }",
    )
    == error.InvalidGuardExpression
}

pub fn guard_unary_minus_rejected_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { y if -y > 0 -> 0 _ -> 1 } }",
    )
    == error.InvalidGuardExpression
}

pub fn guard_todo_rejected_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { y if todo -> 0 _ -> 1 } }",
    )
    == error.TodoInConstant
}

pub fn guard_negative_literal_allowed_test() {
  let _ =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> Int { case x { y if y > -1 -> 0 _ -> 1 } }",
    )
}

pub fn guard_block_allowed_test() {
  let _ =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> Int { case x { y if { y > 0 } -> 0 _ -> 1 } }",
    )
}

pub fn guard_record_construction_allowed_test() {
  let _ =
    helpers.ok_module_typecheck(
      "type Rec { Rec(a: Int, b: Int) } fn foo(x: Rec) -> Int { case x { y if y == Rec(1, 2) -> 0 _ -> 1 } }",
    )
}

pub fn case_pattern_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> String { case x { \"a\" -> \"one\" _ -> \"other\" } }",
    )
    == error.PatternMismatch("string pattern", "String", "Int")
}

pub fn case_clause_body_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { 1 -> 10 _ -> \"other\" } }",
    )
    == error.InvalidType("Int", "String", "in type mismatch")
}

pub fn case_pattern_variable_binds_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> Int { case x { 1 -> 1 y -> y } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(18, 21), "Int", option.None, []),
    )
}

pub fn case_tuple_pattern_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo() -> Int { case #(1, 2) { #(a, b) -> a } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn case_list_pattern_test() {
  assert helpers.error_function_typecheck(
      "fn foo() -> Int { case [1, 2] { [a, ..rest] -> a } }",
    )
    == error.InexhaustivePattern("[]")
}

pub fn use_statement_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn with_x(x: Int, f: fn(Int) -> Int) -> Int { f(x) }
    fn foo() -> Int {
      use y <- with_x(10)
      y + 1
    }",
    )

  let assert [foo_def, _] = module.module.functions
  assert foo_def.definition.return
    == option.Some(
      glance.NamedType(glance.Span(69, 72), "Int", option.None, []),
    )
}

pub fn use_wrong_pattern_count_test() {
  assert helpers.error_module_typecheck(
      "fn with_x(x: Int, f: fn(Int) -> Int) -> Int { f(x) }
    fn foo() -> Int {
      use a, b <- with_x(1)
      a
    }",
    )
    == error.InvalidUse(2)
}

pub fn pipe_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn add(a: Int, b: Int) -> Int { a + b }
    fn foo() -> Int { 1 |> add(2) }",
    )

  let assert [foo_def, _] = module.module.functions
  assert foo_def.definition.return
    == option.Some(
      glance.NamedType(glance.Span(56, 59), "Int", option.None, []),
    )
}

pub fn pipe_bare_function_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn double(x: Int) -> Int { x * 2 }
     fn foo() -> Int { 21 |> double }",
    )
  assert list.length(module.module.functions) == 2
}

pub fn pipe_to_non_callable_test() {
  assert helpers.error_function_typecheck("fn foo() -> Int { 1 |> 5 }")
    == error.NotCallable("Int")
}

pub fn pipe_type_mismatch_test() {
  assert helpers.error_module_typecheck(
      "fn double(x: Int) -> Int { x * 2 }
    fn foo() { \"s\" |> double }",
    )
    == error.InvalidType("String", "Int", "in type mismatch")
}

pub fn pipe_extra_args_test() {
  assert helpers.error_module_typecheck(
      "fn add(a: Int, b: Int) -> Int { a + b }
    fn foo() -> Int { 1 |> add(2, 3) }",
    )
    == error.InvalidArguments("()", "a piped value")
}

pub fn let_bound_used_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo() -> Int {
    let x = 5
    x}",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn let_annotation_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo() {
    let x: String = 5
  }",
    )
    == error.InvalidAnnotation("Int", "String", "x")
}

pub fn zero_arg_variant_constructor_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "pub type Foo { Bar } pub fn main() -> Foo { Bar }",
    )
  assert dict.get(env.scope.definitions, "main")
    == Ok(types.CallableType(
      [],
      dict.new(),
      types.CustomType("main_module", "Foo", [], option.None),
    ))
}

pub fn invalid_escape_string_literal_test() {
  assert helpers.error_function_typecheck("fn foo() -> String { \"a\\1b\" }")
    == error.InvalidEscape("a\\1b")
}

pub fn invalid_escape_string_pattern_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: String) -> Int {
    case x {
      \"a\\1b\" -> 1
      _ -> 0
    }
  }",
    )
    == error.InvalidEscape("a\\1b")
}

pub fn invalid_escape_bit_string_test() {
  assert helpers.error_function_typecheck(
      "fn foo() -> BitArray { <<\"x\\1y\">> }",
    )
    == error.InvalidEscape("x\\1y")
}
