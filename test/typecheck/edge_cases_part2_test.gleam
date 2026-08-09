import glance
import gleam/dict
import gleam/list
import glimpse
import glimpse/error
import glimpse/target
import glimpse/typecheck
import typecheck/helpers

pub fn duplicate_function_definition_test() {
  assert helpers.error_module_typecheck(
      "fn dupe() { 1 }
    fn dupe() { 2 }",
    )
    == error.DuplicateDefinition("dupe")
}

pub fn duplicate_constant_definition_test() {
  assert helpers.error_module_typecheck(
      "const wibble = 1
    pub const wibble = 2",
    )
    == error.DuplicateDefinition("wibble")
}

pub fn duplicate_constant_and_function_definition_test() {
  assert helpers.error_module_typecheck(
      "const value = 1
    fn value() { 2 }",
    )
    == error.DuplicateDefinition("value")
}

pub fn distinct_definitions_are_fine_test() {
  helpers.ok_module_typecheck(
    "const value = 1
    fn other() { 2 }",
  )
}

pub fn duplicate_custom_type_parameter_test() {
  assert helpers.error_module_typecheck("pub type Two(a, a) { Two(a, a) }")
    == error.DuplicateTypeParameter("a")
}

pub fn duplicate_alias_parameter_test() {
  assert helpers.error_module_typecheck("pub type A(a, a) = List(a)")
    == error.DuplicateTypeParameter("a")
}

pub fn duplicate_constructor_label_test() {
  assert helpers.error_module_typecheck("pub type B { B(e0: Int, e0: Int) }")
    == error.DuplicateLabel("e0")
}

pub fn same_label_on_different_variants_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type Person {
      Teacher(name: String, age: Int)
      Student(name: String, age: Int)
    }",
  )
}

pub fn type_used_as_constructor_test() {
  assert helpers.error_module_typecheck("pub fn main() -> Int() { 1 }")
    == error.TypeUsedAsConstructor("Int")
}

pub fn parametric_type_with_no_arguments_test() {
  assert helpers.error_module_typecheck("pub fn main(x: Result()) { x }")
    == error.InvalidType(
      "Result",
      "Result(a, e)",
      "wrong number of type parameters: expected 2, got 0",
    )
}

pub fn external_type_with_constructors_test() {
  assert helpers.error_module_typecheck(
      "@external(erlang, \"gleam_stdlib\", \"dict\")
    pub type Dict(key, value) { Dict(key: key, value: value) }",
    )
    == error.ExternalTypeWithConstructors("Dict")
}

pub fn incorrect_pattern_count_more_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { case 1 { _, _ -> 1 } }",
    )
    == error.IncorrectPatternCount(2, 1)
}

pub fn incorrect_pattern_count_fewer_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { case 1, 2 { x -> 1 } }",
    )
    == error.IncorrectPatternCount(1, 2)
}

pub fn correct_pattern_count_is_fine_test() {
  helpers.ok_module_typecheck("pub fn main() { case 1, 2 { x, y -> x + y } }")
}

pub fn let_assert_message_cannot_use_pattern_binding_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() {
        let assert Ok(message) = Error(\"nope\") as { \"Uh oh: \" <> message }
        message
      }",
    )
    == error.InvalidName("message")
}

pub fn let_assert_message_checked_as_string_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() {
        let assert 5 = 5 as 10
        1
      }",
    )
    == error.InvalidType("Int", "String", "in type mismatch")
}

pub fn float_out_of_range_test() {
  assert helpers.error_module_typecheck("pub fn main() { 1.8e308 }")
    == error.FloatOutOfRange("1.8e308")
}

pub fn float_out_of_range_in_pattern_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { case 1.0 { 1.8e308 -> 1 _ -> 2 } }",
    )
    == error.FloatOutOfRange("1.8e308")
}

pub fn large_but_valid_float_is_fine_test() {
  helpers.ok_module_typecheck("pub fn main() { 1.0e100 }")
}

pub fn float_with_underscores_is_fine_test() {
  helpers.ok_module_typecheck("pub fn main() { 1_000.5 }")
}

pub fn trailing_dot_float_is_fine_test() {
  helpers.ok_module_typecheck("pub fn main() { 1. }")
}

pub fn duplicate_variable_in_tuple_pattern_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { let #(x, x) = #(1, 2) x }",
    )
    == error.DuplicatePatternVariable("x")
}

pub fn duplicate_variable_across_subjects_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { case [1], 2 { x, x -> 1 } }",
    )
    == error.DuplicatePatternVariable("x")
}

pub fn duplicate_variable_in_record_pattern_test() {
  assert helpers.error_module_typecheck(
      "pub type X { X(Int, Int, Int) }
    pub fn main() { case X(1, 2, 3) { X(x, y, x) -> 1 } }",
    )
    == error.DuplicatePatternVariable("x")
}

pub fn alternative_variable_bound_to_different_types_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { case #(1, 1.0) { #(x, _) | #(_, x) -> 1 } }",
    )
    == error.InvalidType("Float", "Int", "in type mismatch")
}

pub fn variable_bound_to_different_positions_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { case [1] { [x] | x -> 1 } }",
    )
    == error.InvalidType("List(Int)", "Int", "in type mismatch")
}

pub fn missing_alternative_pattern_variable_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { case [] { [x] | [] -> x _ -> 0 } }",
    )
    == error.MissingPatternVariable("x")
}

pub fn extra_alternative_pattern_variable_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { case [1] { [x] | [x, y] -> 1 } }",
    )
    == error.ExtraPatternVariable("y")
}

pub fn alternative_patterns_with_consistent_bindings_are_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn main() { case [1, 2] { [x] | [x, ..] -> x _ -> 0 } }",
  )
}

pub fn alternative_bindings_at_different_positions_are_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn main(list1: List(Int), list2: List(Int)) -> Int {
      case list1, list2 {
        [], list | list, [] -> 1
        _, _ -> 0
      }
    }",
  )
}

pub fn duplicate_variable_in_list_pattern_test() {
  assert helpers.error_module_typecheck(
      "pub fn main() { case [1] { [x, x] -> 1 } }",
    )
    == error.DuplicatePatternVariable("x")
}

pub fn pipe_into_complete_call_returning_function_test() {
  helpers.ok_module_typecheck(
    "fn f2(a: Int) { fn(b: Int) { #(a, b) } }
    pub fn main() { let x = 1 |> f2(1) x }",
  )
}

pub fn pipe_fills_first_missing_argument_test() {
  helpers.ok_module_typecheck(
    "fn callback(a: Int) { fn() -> String { \"Called\" } }
    pub fn main() { let x = 1 |> callback() x }",
  )
}

pub fn pipe_into_zero_argument_result_test() {
  assert helpers.error_module_typecheck(
      "fn callback(a: Int) { fn() -> String { \"Called\" } }
    pub fn main() { let x = 1 |> callback(2) x }",
    )
    == error.InvalidArguments("()", "a piped value")
}

pub fn public_other_target_external_is_fine_test() {
  // A public body-less function must have an `@external` for the active build
  // target; one that only implements another target is rejected with
  // "Unsupported target" because every public function must compile for the
  // current target.
  assert helpers.error_module_typecheck(
      "@external(javascript, \"one\", \"two\")
    pub fn js_only() -> Int",
    )
    == error.UnsupportedTarget("js_only")
}

pub fn other_target_external_call_within_module_is_fine_test() {
  // A module may call its own other-target external; the real compiler does
  // not reject dependency modules that do this.
  helpers.ok_module_typecheck(
    "@external(javascript, \"one\", \"two\")
    fn js_only() -> Int
    pub fn main() { js_only() }",
  )
}

pub fn matching_target_external_is_fine_test() {
  helpers.ok_module_typecheck(
    "@external(erlang, \"one\", \"two\")
    pub fn erl_only() -> Int
    pub fn main() { erl_only() }",
  )
}

pub fn unused_other_target_external_is_fine_test() {
  helpers.ok_module_typecheck(
    "@external(javascript, \"one\", \"two\")
    fn js_only() -> Int",
  )
}

pub fn missing_module_import_returns_error_test() {
  let assert Ok(module) =
    glance.module(
      "import one/two
    pub fn main() { two.wibble() }",
    )
  let assert Error(error) =
    typecheck.module(
      glimpse.Module("main_module", module, []),
      dict.new(),
      target.Erlang,
    )
  assert error == error.InvalidName("one/two")
}

pub fn mutually_recursive_type_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "fn one(x) { two([x]) }
    fn two(x) { one(x) }
    pub fn main() { one(1) }",
    )
    == error.RecursiveType
}

pub fn non_recursive_callee_constraint_is_fine_test() {
  helpers.ok_module_typecheck(
    "fn a(x) { b([x]) }
    fn b(y) { y }
    pub fn main() { a(1) }",
  )
}

pub fn int_recursion_is_fine_test() {
  helpers.ok_module_typecheck(
    "fn depth(x) {
      case x {
        0 -> 0
        n -> depth(n - 1)
      }
    }
    pub fn main() { depth(5) }",
  )
}

pub fn parametric_call_chains_are_fine_test() {
  helpers.ok_module_typecheck(
    "fn apply(x: Int, f: fn(Int) -> Int) -> Int { f(x) }
    fn go() -> Int {
      5 |> apply(fn(x: Int) { x + 1 })
    }",
  )
}

pub fn other_target_external_body_is_typechecked_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"one\", \"two\")
    fn x() -> Int {
      \"not an int\"
    }
    pub fn main() { x() }",
    )
    == error.InvalidReturnType("x", "String", "Int")
}

pub fn covered_target_external_body_is_skipped_test() {
  // An external-with-body function has its body typechecked on every target:
  // the body is what actually runs on the other targets. The real compiler
  // requires the body to typecheck even when an external covers this target.
  assert helpers.error_module_typecheck(
      "@external(erlang, \"one\", \"two\")
    fn x() -> Int {
      \"not an int\"
    }
    pub fn main() { x() }",
    )
    == error.InvalidReturnType("x", "String", "Int")
}

pub fn private_other_target_external_call_is_fine_test() {
  helpers.ok_module_typecheck(
    "@external(javascript, \"one\", \"two\")
    fn js_only() -> Int
    fn uh_oh() -> Int { js_only() }
    pub fn main() { uh_oh() }",
  )
}

pub fn named_target_filters_custom_targets_test() {
  // Experimental backends use their own target names via `Named`.
  let assert Ok(module) =
    glance.module(
      "@target(python)
    pub fn python_only() -> Int
    @target(erlang)
    pub fn erlang_only() -> Int",
    )
  let filtered = target.filter_for_target(module, target.Named("python"))
  assert list.map(filtered.functions, fn(def) { def.definition.name })
    == ["python_only"]
}

pub fn named_target_erlang_name_matches_builtin_test() {
  // A `Named("erlang")` target behaves like `Erlang`.
  let assert Ok(module) =
    glance.module(
      "@target(erlang)
    pub fn erl_only() -> Int
    @target(javascript)
    pub fn js_only() -> Int",
    )
  let filtered = target.filter_for_target(module, target.Named("erlang"))
  assert list.map(filtered.functions, fn(def) { def.definition.name })
    == ["erl_only"]
}

pub fn rigid_signature_type_variable_is_enforced_on_return_test() {
  // A function parameter whose type mentions the function's own type variable
  // (`message: fn(List(String)) -> message`) flows that rigid variable through
  // the body. A body that passes a `Decoder(message)` value as a call argument
  // must not have its rigid linkage broken by call-argument instantiation, so
  // a return annotation that renames the variable (`message__zzz`) is a type
  // error rather than unifying with the flexible body type.
  assert helpers.error_module_typecheck(
      "pub type Decoder(a) { Decoder(value: fn(Int) -> a) }
  pub type Attribute(a) { Attribute }
  pub fn subfield(
    path: List(String),
    decoder: Decoder(a),
    next: fn(a) -> Decoder(final),
  ) -> Decoder(final) {
    next(decoder.value(0))
  }
  pub fn success(value: message) -> Decoder(message) {
    Decoder(fn(_) { value })
  }
  pub fn on(name: String, handler: Decoder(message)) -> Attribute(message) {
    Attribute
  }
  pub fn prevent_default(event: Attribute(message)) -> Attribute(message) {
    Attribute
  }
  fn formdata_decoder() -> Decoder(List(String)) {
    Decoder(fn(_) { [] })
  }
  pub fn on_submit(message: fn(List(String)) -> message) -> Attribute(message) {
    on(\"submit\", {
      use formdata <- subfield([\"f\"], formdata_decoder())
      formdata |> message |> success
    })
    |> prevent_default
  }
  pub fn on_submit_bad(message: fn(List(String)) -> message) -> Attribute(message__zzz) {
    on(\"submit\", {
      use formdata <- subfield([\"f\"], formdata_decoder())
      formdata |> message |> success
    })
    |> prevent_default
  }",
    )
    == error.InvalidReturnType(
      "on_submit_bad",
      "main_module.Attribute(message)",
      "main_module.Attribute(message__zzz)",
    )
}

pub fn rigid_signature_type_variable_unmutated_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type Decoder(a) { Decoder(value: fn(Int) -> a) }
  pub type Attribute(a) { Attribute }
  pub fn subfield(
    path: List(String),
    decoder: Decoder(a),
    next: fn(a) -> Decoder(final),
  ) -> Decoder(final) {
    next(decoder.value(0))
  }
  pub fn success(value: message) -> Decoder(message) {
    Decoder(fn(_) { value })
  }
  pub fn on(name: String, handler: Decoder(message)) -> Attribute(message) {
    Attribute
  }
  pub fn prevent_default(event: Attribute(message)) -> Attribute(message) {
    Attribute
  }
  fn formdata_decoder() -> Decoder(List(String)) {
    Decoder(fn(_) { [] })
  }
  pub fn on_submit(message: fn(List(String)) -> message) -> Attribute(message) {
    on(\"submit\", {
      use formdata <- subfield([\"f\"], formdata_decoder())
      formdata |> message |> success
    })
    |> prevent_default
  }",
  )
}
