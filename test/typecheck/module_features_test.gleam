import gleam/dict
import gleam/list
import gleam/set
import glimpse/error
import glimpse/internal/typecheck/types
import typecheck/helpers

pub fn pub_constant_registers_int_test() {
  let #(_module, env) = helpers.ok_module_typecheck("pub const answer = 42")

  assert dict.get(env.definitions, "answer") == Ok(types.IntType)
  assert set.contains(env.public_definitions, "answer")
}

pub fn private_constant_in_definitions_not_public_test() {
  let #(_module, env) = helpers.ok_module_typecheck("const secret = \"hello\"")

  assert dict.get(env.definitions, "secret") == Ok(types.StringType)
  assert set.contains(env.public_definitions, "secret") == False
}

pub fn annotated_constant_matching_annotation_test() {
  let #(_module, env) = helpers.ok_module_typecheck("pub const x: Int = 5")

  assert dict.get(env.definitions, "x") == Ok(types.IntType)
  assert set.contains(env.public_definitions, "x")
}

pub fn annotated_constant_mismatch_error_test() {
  let actual = helpers.error_module_typecheck("pub const x: String = 5")
  assert actual == error.InvalidAnnotation("Int", "String", "x")
}

pub fn constant_use_in_function_body_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "const five = 5
     fn foo() -> Int { five }",
    )
  assert list.length(module.module.functions) == 1
}

pub fn alias_used_in_annotation_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "pub type Temperature = Int
    fn foo() -> Temperature { 5 }",
    )

  assert dict.get(env.custom_types, "Temperature") == Ok(types.IntType)
  assert set.contains(env.public_custom_types, "Temperature")

  assert dict.get(env.definitions, "foo")
    == Ok(types.CallableType([], dict.new(), types.IntType))
}

pub fn private_alias_not_public_test() {
  let #(_module, env) = helpers.ok_module_typecheck("type Alias = Int")

  assert dict.get(env.custom_types, "Alias") == Ok(types.IntType)
  assert set.contains(env.public_custom_types, "Alias") == False
}

pub fn duplicate_type_definition_error_test() {
  let actual =
    helpers.error_module_typecheck(
      "pub type Foo { A }
    type Foo = Int",
    )
  assert actual == error.DuplicateCustomType("Foo")
}

pub fn opaque_type_hides_constructor_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck("pub opaque type Secret { Secret(x: Int) }")

  assert dict.has_key(env.definitions, "Secret")
  assert set.contains(env.public_definitions, "Secret") == False

  assert set.contains(env.public_custom_types, "Secret")

  assert dict.get(env.definitions, "Secret")
    == Ok(types.CallableType(
      [types.IntType],
      dict.from_list([#("x", 0)]),
      types.CustomType("main_module", "Secret"),
    ))
}

pub fn public_type_constructor_is_public_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck("pub type Public { Public(x: Int) }")

  assert set.contains(env.public_definitions, "Public")
}

pub fn opaque_constructor_usable_in_same_module_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "pub opaque type Secret { Secret(x: Int) }
    fn make() -> Secret { Secret(1) }",
    )

  assert dict.has_key(env.definitions, "Secret")
  assert dict.get(env.definitions, "make")
    == Ok(types.CallableType(
      [],
      dict.new(),
      types.CustomType("main_module", "Secret"),
    ))
}

pub fn generic_function_stored_as_generic_callable_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck("fn identity(x: a) -> a { x }")

  let assert Ok(identity_type) = dict.get(env.definitions, "identity")
  let assert types.GenericCallableType(parameters, labels, return, _original) =
    identity_type

  assert parameters == [types.GenericTypeVariable("a")]
  assert labels == dict.new()
  assert return == types.GenericTypeVariable("a")
}

pub fn generic_function_called_with_int_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "fn identity(x: a) -> a { x }
    fn foo() -> Int { identity(1) }",
    )

  assert dict.get(env.definitions, "foo")
    == Ok(types.CallableType([], dict.new(), types.IntType))
}

pub fn generic_function_called_with_string_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "fn identity(x: a) -> a { x }
    fn foo() -> String { identity(\"hi\") }",
    )

  assert dict.get(env.definitions, "foo")
    == Ok(types.CallableType([], dict.new(), types.StringType))
}

pub fn generic_swap_instantiation_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "fn swap(a: x, b: y) -> #(y, x) { #(b, a) }
    fn foo() -> #(String, Int) { swap(1, \"s\") }",
    )

  assert dict.get(env.definitions, "foo")
    == Ok(types.CallableType(
      [],
      dict.new(),
      types.TupleType([types.StringType, types.IntType]),
    ))
}

pub fn generic_return_type_mismatch_test() {
  let actual =
    helpers.error_module_typecheck(
      "fn identity(x: a) -> a { x }
    fn foo() -> Int { identity(\"s\") }",
    )
  assert actual == error.InvalidReturnType("foo", "String", "Int")
}

pub fn generic_list_parameter_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "fn head(xs: List(a)) -> List(a) { xs }
    fn foo() -> List(Int) { head([1, 2, 3]) }",
    )

  assert dict.get(env.definitions, "foo")
    == Ok(types.CallableType([], dict.new(), types.ListType(types.IntType)))
}

pub fn todo_unifies_with_generic_return_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck("fn head(xs: List(a)) -> a { todo }")
  assert dict.has_key(env.definitions, "head")
}
