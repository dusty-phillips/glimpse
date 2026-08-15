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

pub fn public_bodyless_function_without_external_with_private_signature_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(erlang, \"a\", \"b\")
    type PrivateType
    pub fn parse() -> Result(PrivateType, Nil)",
    )
    == error.MissingImplementation("parse")
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

pub fn external_attribute_on_custom_type_wrong_arity_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"a\")
    pub type T",
    )
    == error.InvalidExternalAttribute
}

pub fn external_attribute_on_custom_type_for_arbitrary_target_is_fine_test() {
  helpers.ok_module_typecheck(
    "@external(python, \"a\", \"b\")
pub type T",
  )
}

pub fn external_attribute_on_custom_type_is_fine_test() {
  helpers.ok_module_typecheck(
    "@external(javascript, \"x\", \"y\")
pub type T",
  )
}

pub fn external_attribute_on_variant_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "pub type T {
      @external(javascript, \"x\", \"y\")
      Variant
    }",
    )
    == error.ExternalAttributePlacement("variant")
}

pub fn external_attribute_on_type_alias_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"x\", \"y\")
    type A = Int",
    )
    == error.ExternalAttributePlacement("type alias")
}

pub fn external_attribute_on_import_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"x\", \"y\")
    import gleam/string
    pub fn f() -> String { \"\" }",
    )
    == error.ExternalAttributePlacement("import")
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

pub fn external_attribute_on_constant_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(erlang, \"a\", \"b\")
    const c: Int = 1",
    )
    == error.ExternalAttributePlacement("constant")
}

pub fn internal_attribute_on_constant_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@internal
    const c: Int = 1",
    )
    == error.InvalidAttributePlacement("internal", "constant")
}

pub fn internal_attribute_on_public_constant_is_fine_test() {
  helpers.ok_module_typecheck(
    "@internal
pub const c: Int = 1",
  )
}

pub fn internal_attribute_on_variant_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "pub type T {
      @internal
      T
    }",
    )
    == error.InvalidAttributePlacement("internal", "variant")
}

pub fn target_attribute_on_variant_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "pub type T {
      @target(erlang)
      T
    }",
    )
    == error.InvalidAttributePlacement("target", "variant")
}

pub fn internal_attribute_on_type_alias_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@internal
    type A = Int",
    )
    == error.InvalidAttributePlacement("internal", "type alias")
}

pub fn external_function_missing_param_annotation_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(erlang, \"x\", \"f\")
    pub fn f(x) -> Int {
      x
    }",
    )
    == error.MissingParameterAnnotation("x")
}

pub fn external_function_missing_return_annotation_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(erlang, \"x\", \"f\")
    pub fn f(x: Int) {
      x
    }",
    )
    == error.MissingReturnAnnotation("f")
}

pub fn external_function_with_discarded_unannotated_param_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(erlang, \"x\", \"f\")
    pub fn f(_) -> Int {
      1
    }",
    )
    == error.MissingParameterAnnotation("")
}

pub fn external_function_with_unannotated_labelled_param_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(erlang, \"x\", \"f\")
    pub fn f(y, tag x: Int) -> Int {
      x
    }",
    )
    == error.MissingParameterAnnotation("y")
}

pub fn external_function_with_type_hole_in_param_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(erlang, \"x\", \"f\")
    pub fn f(callback: fn(__zzz) -> Int) -> Int {
      callback(1)
    }",
    )
    == error.UnexpectedTypeHole("_zzz")
}

pub fn external_function_with_type_hole_in_return_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(erlang, \"x\", \"f\")
    fn f(x: Int) -> fn(__zzz) -> Int",
    )
    == error.UnexpectedTypeHole("_zzz")
}

pub fn external_function_with_bare_hole_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(erlang, \"x\", \"f\")
    pub fn f(x: List(_)) -> Int {
      1
    }",
    )
    == error.UnexpectedTypeHole("")
}

pub fn javascript_external_with_invalid_module_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"a b\", \"f\")
    pub fn f() -> Int {
      1
    }",
    )
    == error.InvalidExternalModule("a b")
}

pub fn javascript_external_with_invalid_function_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "@external(javascript, \"m.js\", \"1x\")
    pub fn f() -> Int {
      1
    }",
    )
    == error.InvalidExternalFunction("1x")
}

pub fn javascript_external_with_valid_names_is_fine_test() {
  helpers.ok_module_typecheck(
    "@external(javascript, \"../gleam_stdlib.mjs\", \"map\")
pub fn f() -> Int {
  1
}",
  )
}

pub fn erlang_external_module_paths_are_not_validated_test() {
  helpers.ok_module_typecheck(
    "@external(erlang, \"ma p\", \"f g\")
pub fn f() -> Int {
  1
}",
  )
}

pub fn other_target_external_does_not_require_annotations_test() {
  helpers.ok_module_typecheck(
    "@external(javascript, \"x\", \"f\")
pub fn f(x) {
  x
}",
  )
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

pub fn bodyless_function_without_external_is_rejected_test() {
  assert helpers.error_module_typecheck("pub fn f() -> Int")
    == error.MissingImplementation("f")
}

pub fn private_bodyless_function_without_external_is_rejected_test() {
  assert helpers.error_module_typecheck("fn f() -> Int")
    == error.MissingImplementation("f")
}

pub fn empty_brace_body_is_an_implementation_test() {
  helpers.ok_module_typecheck(
    "pub fn f() -> Nil {}
pub fn g() -> Int {
  1
}",
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

pub fn opaque_block_and_bodyless_forms_parse_fine_test() {
  let assert Ok(_) = glance.module("pub opaque type X {\n  X\n}")
  let assert Ok(_) = glance.module("pub opaque type Y")
  Nil
}

pub fn type_definition_with_unlabelled_field_after_labelled_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "pub type Foo {
    Foo(a: Int, Bool)
  }",
    )
    == error.UnlabelledArgumentAfterLabelled
}

pub fn type_definition_labelled_after_unlabelled_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type Foo {
  Foo(Int, a: Bool)
}",
  )
}

pub fn public_alias_referencing_private_type_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "pub type Handle(a)

type D

pub type DirectoryHandle =
  Handle(D)

pub fn show() -> DirectoryHandle {
  todo
}",
    )
    == error.PrivateTypeLeak("D")
}

pub fn public_alias_referencing_private_type_without_public_use_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type Handle(a)

type D

pub type DirectoryHandle =
  Handle(D)

pub fn main() -> Nil {
  Nil
}",
  )
}

pub fn public_alias_referencing_public_type_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type Handle(a)

pub type D

pub type DirectoryHandle =
  Handle(D)

pub fn show() -> DirectoryHandle {
  todo
}",
  )
}

pub fn alias_with_undeclared_type_variable_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "pub type TemplateName = ng

pub fn main() -> Nil {
  Nil
}",
    )
    == error.UnknownCustomType("ng")
}

pub fn alias_with_declared_type_variable_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type Template(a) = List(a)

pub fn main() -> Nil {
  Nil
}",
  )
}

pub fn snake_case_names_are_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn do_stuff(foo_bar: Int) -> Int {
  foo_bar
}",
  )
}

pub fn snake_case_type_variable_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn start() -> child_data {
  todo
}",
  )
}

/// Disabled: the published glexer lexes leading-underscore names differently, so this source never reaches the typechecker. Kept as documentation of the former typechecker-level check.
pub fn type_name_with_underscore_is_rejected() {
  assert helpers.error_module_typecheck("pub type Foo_bar {\n  Foo_bar\n}")
    == error.InvalidTypeName("Foo_bar")
}

/// Disabled: the published glexer lexes leading-underscore names differently, so this source never reaches the typechecker. Kept as documentation of the former typechecker-level check.
pub fn variant_name_with_underscore_is_rejected() {
  assert helpers.error_module_typecheck("pub type X {\n  Bar_\n}")
    == error.InvalidVariantName("Bar_")
}

/// Disabled: the published glexer lexes leading-underscore names differently, so this source never reaches the typechecker. Kept as documentation of the former typechecker-level check.
pub fn alias_name_with_underscore_is_rejected() {
  assert helpers.error_module_typecheck("type A_b = Int")
    == error.InvalidTypeAliasName("A_b")
}

/// Disabled: the published glance accepts `pub opaque type A(a) = #(a, Int)`, so this is no longer a parse error. Kept as documentation.
pub fn opaque_type_alias_is_a_parse_error() {
  let assert Error(_) = glance.module("pub opaque type A(a) = #(a, Int)")
  Nil
}

/// Disabled: the published glexer rejects camelCase identifiers at lex time, so this source never reaches the typechecker. Kept as documentation of the former typechecker-level check.
pub fn function_with_uppercase_in_name_is_rejected() {
  assert helpers.error_module_typecheck("pub fn doStuff() -> Int {\n  1\n}")
    == error.InvalidFunctionName("doStuff")
}

/// Disabled: the published glexer rejects camelCase identifiers at lex time, so this source never reaches the typechecker. Kept as documentation of the former typechecker-level check.
pub fn constant_with_uppercase_in_name_is_rejected() {
  assert helpers.error_module_typecheck("const fooBar = 1")
    == error.InvalidConstantName("fooBar")
}

/// Disabled: the published glexer rejects camelCase identifiers at lex time, so this source never reaches the typechecker. Kept as documentation of the former typechecker-level check.
pub fn argument_with_uppercase_in_name_is_rejected() {
  assert helpers.error_module_typecheck(
      "pub fn f(myVar: Int) -> Int {\n  myVar\n}",
    )
    == error.InvalidArgumentName("myVar")
}

/// Disabled: the published glexer rejects camelCase identifiers at lex time, so this source never reaches the typechecker. Kept as documentation of the former typechecker-level check.
pub fn type_variable_with_uppercase_in_name_is_rejected() {
  assert helpers.error_module_typecheck("pub type Foo(fooBar) {\n  Foo\n}")
    == error.InvalidTypeVariableName("fooBar")
}

/// Disabled: the published glexer rejects camelCase identifiers at lex time, so this source never reaches the typechecker. Kept as documentation of the former typechecker-level check.
pub fn camel_case_type_variable_in_signature_is_rejected() {
  assert helpers.error_module_typecheck(
      "pub type Builder(a, b) {
  Builder
}

pub fn start(builder: Builder(child_argument, child_dataInt)) -> Nil {
  Nil
}",
    )
    == error.InvalidTypeVariableName("child_dataInt")
}

/// Disabled: the published glexer rejects camelCase identifiers at lex time, so this source never reaches the typechecker. Kept as documentation of the former typechecker-level check.
pub fn camel_case_type_variable_in_return_is_rejected() {
  assert helpers.error_module_typecheck(
      "pub fn start() -> child_dataInt {
  todo
}",
    )
    == error.InvalidTypeVariableName("child_dataInt")
}

pub fn empty_braces_body_without_return_annotation_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn main() {}
pub fn g() -> Int {
  1
}",
  )
}

pub fn external_for_unmodelled_target_is_supported_test() {
  helpers.ok_module_typecheck(
    "@external(python, \"os\", \"getenv\")
pub fn get_env(name: String) -> String

pub fn read_env() -> String {
  get_env(\"HOME\")
}

pub fn main() -> Nil {
  Nil
}",
  )
}

pub fn private_external_for_unmodelled_target_is_fine_test() {
  helpers.ok_module_typecheck(
    "@external(rust, \"sys\", \"ffi\")
fn ffi_call() -> Int",
  )
}
