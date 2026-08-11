import glance
import gleam/dict
import glimpse
import glimpse/error
import glimpse/target
import glimpse/typecheck
import typecheck/helpers

pub fn duplicate_constructor_names_test() {
  assert helpers.error_module_typecheck("pub type Boxy { Box(Int) Box(Float) }")
    == error.DuplicateConstructor("Box")
}

pub fn distinct_constructor_names_test() {
  helpers.ok_module_typecheck("pub type Boxy { Box(Int) Wobble(Float) }")
}

pub fn duplicate_constructor_names_across_types_test() {
  assert helpers.error_module_typecheck("pub type X { A } pub type Y { A }")
    == error.DuplicateConstructor("A")
}

pub fn duplicate_constructor_names_across_types_is_fine_test() {
  helpers.ok_module_typecheck("pub type X { A } pub type Y { B }")
}

pub fn private_type_leaking_through_public_signature_test() {
  assert helpers.error_module_typecheck(
      "type PrivateType
  @external(erlang, \"a\", \"b\")
  pub fn leak_type() -> PrivateType",
    )
    == error.PrivateTypeLeak("PrivateType")
}

pub fn private_type_in_private_function_is_fine_test() {
  helpers.ok_module_typecheck(
    "type PrivateType = Int
fn helper() -> PrivateType {
  1
}",
  )
}

pub fn prelude_type_in_public_signature_is_fine_test() {
  helpers.ok_module_typecheck(
    "@external(erlang, \"a\", \"b\")
  pub fn parse(string: String) -> Result(Float, Nil)",
  )
}

pub fn imported_type_in_public_signature_is_fine_test() {
  helpers.ok_package_check("main_module", fn(pkg) {
    case pkg {
      "main_module" ->
        Ok(
          "import other/package.{type Order}

        @external(erlang, \"a\", \"b\")
        pub fn compare(a: Int, b: Int) -> Order",
        )
      "other/package" ->
        Ok(
          "pub type Order {
          Lesser
          Equal
          Greater
        }",
        )
      _ -> panic as "only two modules in this test"
    }
  })
}

pub fn private_type_nested_in_public_signature_test() {
  assert helpers.error_module_typecheck(
      "@external(erlang, \"a\", \"b\")
    type PrivateType
    pub fn parse() -> Result(PrivateType, Nil)",
    )
    == error.PrivateTypeLeak("PrivateType")
}

pub fn todo_in_a_constant_test() {
  assert helpers.error_module_typecheck("pub const wibble = todo")
    == error.TodoInConstant
}

pub fn fn_literal_in_a_constant_test() {
  assert helpers.error_module_typecheck("pub const f = fn(x) { x }")
    == error.FnInConstant
}

pub fn fn_literal_nested_in_constant_test() {
  assert helpers.error_module_typecheck(
      "type Box(a) { Box(a) } pub const b = Box(fn() { 1 })",
    )
    == error.FnInConstant
}

pub fn fn_capture_in_constant_is_fine_test() {
  helpers.ok_module_typecheck("fn id(x: Int) -> Int { x } pub const f = id")
}

pub fn constant_with_value_is_fine_test() {
  helpers.ok_module_typecheck("pub const wibble = 42")
}

pub fn constant_with_operator_expression_test() {
  assert helpers.error_module_typecheck("pub const wibble = 1 + 2")
    == error.InvalidConstantExpression
}

pub fn constant_with_arithmetic_comparison_test() {
  assert helpers.error_module_typecheck("pub const wibble = 1 == 2")
    == error.InvalidConstantExpression
}

pub fn constant_with_block_test() {
  assert helpers.error_module_typecheck("pub const wibble = { 1 }")
    == error.InvalidConstantExpression
}

pub fn constant_with_panic_test() {
  assert helpers.error_module_typecheck("pub const wibble = panic")
    == error.InvalidConstantExpression
}

pub fn constant_with_string_concat_is_fine_test() {
  helpers.ok_module_typecheck("pub const wibble = \"a\" <> \"b\"")
}

pub fn constant_with_record_is_fine_test() {
  helpers.ok_module_typecheck(
    "type Box(a) { Box(a) } pub const wibble = Box(1)",
  )
}

pub fn constant_with_negated_literal_is_fine_test() {
  helpers.ok_module_typecheck("pub const wibble = -1")
}

pub fn external_attribute_wrong_arity_test() {
  assert helpers.error_module_typecheck(
      "@external(erlang, \"a\")
    pub fn f() -> Int { 1 }",
    )
    == error.InvalidExternalAttribute
}

pub fn external_attribute_non_variable_target_test() {
  assert helpers.error_module_typecheck(
      "@external(\"str\", \"a\", \"b\")
    pub fn f() -> Int { 1 }",
    )
    == error.InvalidExternalAttribute
}

pub fn deprecated_attribute_without_message_test() {
  assert helpers.error_module_typecheck(
      "@deprecated
    pub fn f() -> Int { 1 }",
    )
    == error.InvalidAttributeShape("deprecated")
}

pub fn deprecated_attribute_with_non_string_message_test() {
  assert helpers.error_module_typecheck(
      "@deprecated(123)
    pub fn f() -> Int { 1 }",
    )
    == error.InvalidAttributeShape("deprecated")
}

pub fn deprecated_attribute_with_message_is_fine_test() {
  helpers.ok_module_typecheck(
    "@deprecated(\"use g instead\")
pub fn f() -> Int { 1 }",
  )
}

pub fn target_attribute_with_wrong_arity_test() {
  assert helpers.error_module_typecheck(
      "@target(erlang, javascript)
    pub fn f() -> Int { 1 }",
    )
    == error.InvalidAttributeShape("target")
}

pub fn target_attribute_with_non_variable_test() {
  assert helpers.error_module_typecheck(
      "@target(\"erlang\")
    pub fn f() -> Int { 1 }",
    )
    == error.InvalidAttributeShape("target")
}

pub fn unknown_target_attribute_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@target(python)
    pub fn f() -> Int { 1 }",
    )
    == error.UnknownTarget("python")
}

pub fn known_target_attribute_is_fine_test() {
  helpers.ok_module_typecheck(
    "@target(javascript)
pub fn f() -> Int { 1 }",
  )
}

pub fn external_function_missing_param_annotation_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"x\", \"f\")
    pub fn f(x) -> Int {
      x
    }",
    )
    == error.MissingParameterAnnotation("x")
}

pub fn external_function_missing_return_annotation_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"x\", \"f\")
    pub fn f(x: Int) {
      x
    }",
    )
    == error.MissingReturnAnnotation("f")
}

pub fn external_function_with_discarded_unannotated_param_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"x\", \"f\")
    pub fn f(_) -> Int {
      1
    }",
    )
    == error.MissingParameterAnnotation("")
}

pub fn external_function_with_unannotated_labelled_param_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"x\", \"f\")
    pub fn f(tag x: Int, y) -> Int {
      x
    }",
    )
    == error.MissingParameterAnnotation("y")
}

pub fn external_function_with_type_hole_in_param_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"x\", \"f\")
    pub fn f(callback: fn(__zzz) -> Int) -> Int {
      callback(1)
    }",
    )
    == error.UnexpectedTypeHole("_zzz")
}

pub fn external_function_with_type_hole_in_return_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"x\", \"f\")
    fn f(x: Int) -> fn(__zzz) -> Int",
    )
    == error.UnexpectedTypeHole("_zzz")
}

pub fn external_function_with_bare_hole_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"x\", \"f\")
    pub fn f(x: List(_)) -> Int {
      1
    }",
    )
    == error.UnexpectedTypeHole("")
}

pub fn non_external_function_with_type_hole_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn g(x: List(_)) -> Int {
  1
}",
  )
}

pub fn internal_attribute_with_argument_test() {
  assert helpers.error_module_typecheck(
      "@internal(\"x\")
    pub fn f() -> Int { 1 }",
    )
    == error.InvalidAttributeShape("internal")
}

pub fn record_update_on_unlabelled_constructor_test() {
  assert helpers.error_module_typecheck(
      "pub type M { M(Int) }
    pub fn f() -> M {
      let base = M(1)
      M(..base)
    }",
    )
    == error.RecordUpdateOnUnlabelledConstructor("M")
}

pub fn record_update_on_labelled_constructor_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type M { M(a: Int) }
pub fn f() -> M {
  let base = M(1)
  M(..base, a: 2)
}",
  )
}

pub fn type_alias_with_unused_parameter_test() {
  assert helpers.error_module_typecheck("type A(a) = Int")
    == error.UnusedTypeParameter("a")
}

pub fn type_alias_using_parameter_test() {
  helpers.ok_module_typecheck("type A(a) = List(a)")
}

pub fn duplicate_attribute_on_function_test() {
  assert helpers.error_module_typecheck(
      "@deprecated(\"a\")
    @deprecated(\"b\")
    pub fn f() -> Int { 1 }",
    )
    == error.DuplicateAttribute("deprecated")
}

pub fn duplicate_target_attribute_test() {
  assert helpers.error_module_typecheck(
      "@target(erlang)
    @target(javascript)
    pub fn f() -> Int { 1 }",
    )
    == error.DuplicateAttribute("target")
}

pub fn duplicate_internal_attribute_test() {
  assert helpers.error_module_typecheck(
      "@internal
    @internal
    pub fn f() -> Int { 1 }",
    )
    == error.DuplicateAttribute("internal")
}

pub fn duplicate_external_attribute_same_target_test() {
  assert helpers.error_module_typecheck(
      "@external(erlang, \"m\", \"f\")
    @external(erlang, \"m\", \"f\")
    pub fn f() -> Int",
    )
    == error.DuplicateAttribute("external")
}

pub fn external_attribute_for_multiple_targets_is_fine_test() {
  helpers.ok_module_typecheck(
    "@external(erlang, \"m\", \"f\")
    @external(javascript, \"m\", \"f\")
    pub fn f() -> Int",
  )
}

pub fn duplicate_attribute_on_type_and_variant_test() {
  assert helpers.error_module_typecheck(
      "@deprecated(\"a\")
    pub type X {
      @deprecated(\"b\")
      A
    }",
    )
    == error.DuplicateAttribute("deprecated")
}

pub fn duplicate_attribute_on_separate_types_is_fine_test() {
  helpers.ok_module_typecheck(
    "@deprecated(\"a\")
    pub type X { A }

    @deprecated(\"b\")
    pub type Y { B }",
  )
}

pub fn public_unsupported_target_external_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"m\", \"f\")
    pub fn f() -> Int",
    )
    == error.UnsupportedTarget("f")
}

pub fn private_unsupported_target_external_is_fine_test() {
  helpers.ok_module_typecheck(
    "@external(javascript, \"m\", \"f\")
    fn f() -> Int",
  )
}

pub fn supported_target_external_is_fine_test() {
  helpers.ok_module_typecheck(
    "@external(erlang, \"m\", \"f\")
    pub fn f() -> Int",
  )
}

pub fn unsupported_target_external_in_dependency_is_fine_test() {
  // The real compiler only enforces target support for the package being
  // checked, not its dependencies: a dependency's erlang-only external must
  // not fail a javascript-target project (and vice versa).
  let assert Ok(module) =
    glance.module(
      "@external(erlang, \"m\", \"f\")
    pub fn f() -> Int",
    )
  let assert Ok(result) =
    typecheck.module(
      glimpse.Module("dep_module", module, []),
      dict.new(),
      target.Javascript,
      False,
    )
  let #(_module, _env) = result
}

pub fn invalid_external_on_other_target_is_rejected_test() {
  // Attribute and constant grammar are parse-time checks in the real compiler:
  // a definition filtered out for the current build target is still validated.
  // A malformed `@external` on a `@target(javascript)` function must be
  // rejected even while checking the erlang target.
  assert helpers.error_module_typecheck(
      "@target(javascript)
    @external(javascript, \"m\", \"f\", \"c\")
    pub fn f() -> Int",
    )
    == error.InvalidExternalAttribute
}

pub fn invalid_constant_on_other_target_is_rejected_test() {
  // A constant whose value is not valid constant grammar is a parse error even
  // when the constant is filtered out for the current target.
  assert helpers.error_module_typecheck(
      "@target(javascript)
    pub const x = fn() { 1 }",
    )
    == error.FnInConstant
}

pub fn invalid_constant_on_other_target_typechecks_value_test() {
  assert helpers.error_module_typecheck(
      "@target(javascript)
    pub const x = 1 + 1",
    )
    == error.InvalidConstantExpression
}

pub fn duplicate_parameter_names_in_definition_test() {
  assert helpers.error_module_typecheck(
      "pub fn start(conn, params, params) -> Int { conn }",
    )
    == error.DuplicateArgumentName("params")
}

pub fn distinct_parameter_names_in_definition_is_fine_test() {
  helpers.ok_module_typecheck("pub fn start(conn, params) -> Int { conn }")
}
