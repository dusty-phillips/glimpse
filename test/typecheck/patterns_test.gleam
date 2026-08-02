import glance
import gleam/list
import gleam/option
import glimpse/error
import typecheck/helpers

pub fn case_int_pattern_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> Int { case x { 1 -> 1 _ -> 0 } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(18, 21), "Int", option.None, []),
    )
}

pub fn case_int_pattern_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: String) -> Int { case x { 1 -> 1 _ -> 0 } }",
    )
    == error.PatternMismatch("int pattern", "Int", "String")
}

pub fn case_float_pattern_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: Float) -> Float { case x { 1.0 -> 1.0 _ -> 0.0 } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(20, 25), "Float", option.None, []),
    )
}

pub fn case_float_pattern_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Float { case x { 1.0 -> 1.0 _ -> 0.0 } }",
    )
    == error.PatternMismatch("float pattern", "Float", "Int")
}

pub fn case_string_pattern_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: String) -> String { case x { \"a\" -> \"one\" _ -> \"other\" } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(21, 27), "String", option.None, []),
    )
}

pub fn case_string_pattern_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { \"a\" -> 1 _ -> 0 } }",
    )
    == error.PatternMismatch("string pattern", "String", "Int")
}

pub fn case_tuple_pattern_arity_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo() -> Int { case #(1, 2) { #(a, b, c) -> a } }",
    )
    == error.PatternMismatch("tuple pattern", "(Int, Int)", "tuple")
}

pub fn case_tuple_pattern_on_non_tuple_test() {
  assert helpers.error_function_typecheck(
      "fn foo() -> Int { case 5 { #(a, b) -> a } }",
    )
    == error.PatternMismatch("tuple pattern", "Int", "tuple")
}

pub fn case_list_pattern_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo() -> Int { case 5 { [a] -> a } }",
    )
    == error.PatternMismatch("list pattern", "List", "Int")
}

pub fn case_variant_pattern_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "pub type MyResult {
    MyOk(value: Int)
    MyErr
  }
  fn foo(x: MyResult) -> Int {
    case x {
      MyOk(v) -> v
      MyErr -> 0
    }
  }",
    )

  let assert [foo_def] = module.module.functions
  assert foo_def.definition.return
    == option.Some(
      glance.NamedType(glance.Span(80, 83), "Int", option.None, []),
    )
}

pub fn case_variant_labelled_pattern_test() {
  helpers.ok_module_typecheck(
    "pub type Person {
    Person(name: String, age: Int)
  }
  fn foo(p: Person) -> Int {
    case p {
      Person(name: _, age: a) -> a
    }
  }",
  )
}

pub fn case_variant_scrutinee_mismatch_test() {
  assert helpers.error_module_typecheck(
      "pub type MyResult {
    MyOk(value: Int)
    MyErr
  }
  fn foo() -> Int {
    case 5 {
      MyOk(v) -> v
      MyErr -> 0
    }
  }",
    )
    == error.InvalidType("Int", "main_module.MyResult", "in type mismatch")
}

pub fn case_string_concat_pattern_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: String) -> String { case x { \"a\" <> rest -> rest } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(21, 27), "String", option.None, []),
    )
}

pub fn case_string_concat_pattern_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> String { case x { \"a\" <> rest -> rest } }",
    )
    == error.PatternMismatch("string concatenation pattern", "String", "Int")
}

pub fn case_bit_string_pattern_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo() -> Int { case <<1>> { <<n>> -> n } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn case_bit_string_pattern_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo() -> Int { case 5 { <<n>> -> n } }",
    )
    == error.PatternMismatch("bit array pattern", "BitArray", "Int")
}

pub fn case_assignment_pattern_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> Int { case x { 1 as one -> one _ -> 0 } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(18, 21), "Int", option.None, []),
    )
}

pub fn case_discard_pattern_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> Int { case x { 1 -> 1 _ -> 0 } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(18, 21), "Int", option.None, []),
    )
}

pub fn let_tuple_pattern_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo() -> Int {
    let #(a, b) = #(1, 2)
    a}",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn let_tuple_pattern_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo() {
    let #(a, b) = 5
  }",
    )
    == error.PatternMismatch("tuple pattern", "Int", "tuple")
}

pub fn let_list_pattern_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo() {
    let [a, b] = 5
  }",
    )
    == error.PatternMismatch("list pattern", "List", "Int")
}

pub fn let_variable_rebind_same_type_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> Int {
    let x = 1
    x}",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(18, 21), "Int", option.None, []),
    )
}

pub fn let_variable_rebind_different_type_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int {
    let x = \"a\"
    x}",
    )
    == error.InvalidType(
      "Int",
      "String",
      "cannot rebind variable with different type",
    )
}

pub fn let_assert_custom_type_pattern_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "pub type MyResult {
    MyOk(value: Int)
    MyErr
  }
  fn foo(x: MyResult) -> Int {
    let assert MyOk(v) = x
    v
  }",
    )
  assert list.length(module.module.functions) == 1
}
