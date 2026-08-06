import glimpse/error
import typecheck/helpers

pub fn duplicate_constructor_names_test() {
  assert helpers.error_module_typecheck("pub type Boxy { Box(Int) Box(Float) }")
    == error.DuplicateConstructor("Box")
}

pub fn distinct_constructor_names_test() {
  helpers.ok_module_typecheck("pub type Boxy { Box(Int) Wobble(Float) }")
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

pub fn constant_with_value_is_fine_test() {
  helpers.ok_module_typecheck("pub const wibble = 42")
}

pub fn type_alias_with_unused_parameter_test() {
  assert helpers.error_module_typecheck("type A(a) = Int")
    == error.UnusedTypeParameter("a")
}

pub fn type_alias_using_parameter_test() {
  helpers.ok_module_typecheck("type A(a) = List(a)")
}
