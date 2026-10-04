import glance
import glimpse/error
import typecheck/helpers

// Every located error carries the exact source span of the offending syntax.
// Offsets are byte offsets into the definition string passed to the helper.

pub fn unknown_type_points_at_annotation_test() {
  assert helpers.error_located_module_typecheck(
      "pub fn main() -> Wibble {\n  1\n}",
    )
    == error.LocatedError(
      glance.Span(17, 23),
      error.UnknownCustomType("Wibble"),
    )
}

pub fn return_type_points_at_annotation_test() {
  assert helpers.error_located_module_typecheck(
      "pub fn main() -> Int {\n  \"s\"\n}",
    )
    == error.LocatedError(
      glance.Span(17, 20),
      error.InvalidReturnType("main", "String", "Int"),
    )
}

pub fn undefined_variable_points_at_use_site_test() {
  assert helpers.error_located_module_typecheck(
      "pub fn main() -> Int {\n  undefined_var\n}",
    )
    == error.LocatedError(
      glance.Span(25, 38),
      error.InvalidName("undefined_var"),
    )
}

pub fn binop_mismatch_points_at_whole_expression_test() {
  assert helpers.error_located_module_typecheck(
      "pub fn main() -> Bool {\n  1 == \"s\"\n}",
    )
    == error.LocatedError(
      glance.Span(26, 34),
      error.InvalidBinOp("==", "Int", "String", "same type"),
    )
}

pub fn arithmetic_mismatch_points_at_whole_expression_test() {
  assert helpers.error_located_module_typecheck(
      "pub fn main() -> Int {\n  1 + 1.5\n}",
    )
    == error.LocatedError(
      glance.Span(25, 32),
      error.InvalidBinOp("+", "Int", "Float", "two Ints"),
    )
}

pub fn lowercase_bool_pattern_points_at_pattern_test() {
  assert helpers.error_located_function_typecheck(
      "fn foo() { let true = True }",
    )
    == error.LocatedError(
      glance.Span(15, 19),
      error.LowercaseBoolPattern("true"),
    )
}

pub fn float_out_of_range_points_at_literal_test() {
  assert helpers.error_located_module_typecheck("pub fn main() { 1.8e308 }")
    == error.LocatedError(glance.Span(16, 23), error.FloatOutOfRange("1.8e308"))
}

pub fn invalid_escape_points_at_literal_test() {
  assert helpers.error_located_module_typecheck(
      "pub fn main() -> String {\n  \"\\1\"\n}",
    )
    == error.LocatedError(glance.Span(28, 32), error.InvalidEscape("\\1"))
}

pub fn non_bool_guard_points_at_guard_expression_test() {
  assert helpers.error_located_module_typecheck(
      "pub fn main(x: Int) -> Int {\n  case x {\n    _ if x -> 1\n    _ -> 2\n  }\n}",
    )
    == error.LocatedError(glance.Span(49, 50), error.InvalidGuard("Int"))
}

pub fn pattern_arity_points_at_pattern_test() {
  assert helpers.error_located_module_typecheck(
      "pub type T {\n  V(a: Int, b: Int)\n}\npub fn main(x: T) -> Int {\n  case x {\n    V(a) -> a\n  }\n}",
    )
    == error.LocatedError(glance.Span(77, 81), error.InvalidPatternArity(2, 1))
}

pub fn missing_parameter_annotation_points_at_function_test() {
  // No annotation node exists, so the enclosing function is the honest span.
  assert helpers.error_located_module_typecheck(
      "@external(erlang, \"m\", \"f\")\npub fn main(x) -> Int",
    )
    == error.LocatedError(
      glance.Span(28, 49),
      error.MissingParameterAnnotation("x"),
    )
}

pub fn call_arity_falls_back_to_enclosing_function_test() {
  // Arity is computed from field lists without syntax attached, so the
  // enclosing function is the span rather than a precise argument.
  assert helpers.error_located_module_typecheck(
      "fn id(x: Int) -> Int {\n  x\n}\npub fn main() -> Int {\n  id(1, 2)\n}",
    )
    == error.LocatedError(
      glance.Span(29, 64),
      error.InvalidArguments("(Int)", "(Int, Int)"),
    )
}

pub fn todo_in_constant_points_at_constant_test() {
  assert helpers.error_located_module_typecheck("const x = todo")
    == error.LocatedError(glance.Span(0, 14), error.TodoInConstant)
}

pub fn module_level_duplicate_has_unknown_span_test() {
  // Module-scope duplicate detection works on name strings with no syntax
  // attached; the span is unknown and renderers must cope without a frame.
  assert helpers.error_located_module_typecheck(
      "pub fn f() -> Int {\n  1\n}\npub fn f() -> Int {\n  2\n}",
    )
    == error.LocatedError(glance.Span(-1, -1), error.DuplicateDefinition("f"))
}

pub fn unify_mismatch_falls_back_to_enclosing_function_test() {
  // Unification works on types rather than syntax, so a bare mismatch
  // carries no span of its own; the enclosing function is the honest span.
  assert helpers.error_located_module_typecheck(
      "pub fn main() -> List(Int) {\n  [1, \"s\"]\n}",
    )
    == error.LocatedError(
      glance.Span(0, 41),
      error.InvalidType("Int", "String", "in type mismatch"),
    )
}
