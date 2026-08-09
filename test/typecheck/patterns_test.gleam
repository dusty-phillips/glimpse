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
  assert helpers.error_function_typecheck(
      "fn foo(x: String) -> String { case x { \"a\" <> rest -> rest } }",
    )
    == error.InexhaustivePattern("_")
}

pub fn case_string_concat_pattern_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> String { case x { \"a\" <> rest -> rest } }",
    )
    == error.PatternMismatch("string concatenation pattern", "String", "Int")
}

pub fn case_bit_string_pattern_test() {
  assert helpers.error_function_typecheck(
      "fn foo() -> Int { case <<1>> { <<n>> -> n } }",
    )
    == error.InexhaustivePattern("_")
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

pub fn let_variable_shadows_parameter_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> String {
    let x = \"a\"
    x}",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(18, 24), "String", option.None, []),
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

pub fn lowercase_bool_case_pattern_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Bool) -> Int { case x { true -> 0 false -> 1 } }",
    )
    == error.LowercaseBoolPattern("true")
}

pub fn lowercase_bool_let_pattern_test() {
  assert helpers.error_function_typecheck("fn foo() { let true = True }")
    == error.LowercaseBoolPattern("true")
}

pub fn lowercase_bool_shadow_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Bool) -> Int { case x { false -> 0 _ -> 1 } }",
    )
    == error.LowercaseBoolPattern("false")
}

pub fn string_concat_pattern_allowed_test() {
  let _ =
    helpers.ok_function_typecheck(
      "fn foo(x: String) -> Int { case x { \"a\" <> rest -> 1 _ -> 0 } }",
    )
}

pub fn string_concat_pattern_prefix_must_match_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { \"a\" <> rest -> 1 _ -> 0 } }",
    )
    == error.PatternMismatch("string concatenation pattern", "String", "Int")
}

pub fn string_concat_pattern_with_typed_tail_is_fine_test() {
  // The tail of a string-concatenation pattern may be a typed pattern that
  // refines the subject further.
  let _ =
    helpers.ok_function_typecheck(
      "fn foo(x: String) -> Int { case x { \"a\" <> rest if rest == \"\" -> 1 _ -> 0 } }",
    )
}

pub fn string_concat_pattern_rebinding_subject_variable_test() {
  // A string-concatenation pattern whose tail rebinds the subject variable
  // (`"a" <> state`) means the name now refers to the tail, so the subject
  // variable must not be refined as a variant. Exercises the
  // `pattern_binds_name` PatternConcatenate branch.
  let _ =
    helpers.ok_function_typecheck(
      "fn foo(state: String) -> Int { case state { \"a\" <> state -> 1 _ -> 0 } }",
    )
}

pub fn unknown_label_in_constructor_pattern_test() {
  assert helpers.error_module_typecheck(
      "pub type Wibble { Wibble(a: Int) }
    pub fn foo(w: Wibble) -> Int { case w { Wibble(zzz: _) -> 1 } }",
    )
    == error.InvalidArgumentLabel("(a)", "zzz")
}
