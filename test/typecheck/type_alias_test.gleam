import gleam/dict
import gleam/option

import gleam/set
import glimpse/error
import glimpse/internal/typecheck/types
import typecheck/helpers

pub fn parameterized_alias_in_annotation_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "pub type Wrap(a) = List(a)
    fn f(xs: Wrap(Int)) -> List(Int) { xs }",
    )

  assert dict.get(env.scope.definitions, "f")
    == Ok(types.CallableType(
      [types.CustomType("gleam", "List", [types.IntType], option.None)],
      dict.new(),
      types.CustomType("gleam", "List", [types.IntType], option.None),
    ))
}

pub fn alias_referencing_custom_type_declared_later_test() {
  let #(_module, _env) =
    helpers.ok_module_typecheck(
      "type Handle(a) = Result(a, Err)
    pub type Err { Err }
    fn f() -> Handle(Int) { Ok(42) }",
    )
}

pub fn alias_referencing_another_alias_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "type A = Int
    type B = A
    fn f() -> B { 5 }",
    )

  assert dict.get(env.custom_types, "B")
    == Ok(types.TypeAlias([], types.IntType))
}

pub fn alias_wrong_number_of_parameters_test() {
  let actual =
    helpers.error_module_typecheck(
      "type Wrap(a) = List(a)
    fn f() -> Wrap { [] }",
    )

  assert actual
    == error.InvalidType(
      "Wrap",
      "List(a)",
      "wrong number of type parameters: expected 1, got 0",
    )
}

pub fn duplicate_alias_test() {
  let actual =
    helpers.error_module_typecheck(
      "type Bar = Int
    type Bar = String",
    )

  assert actual == error.DuplicateCustomType("Bar")
}

pub fn private_alias_not_public_test() {
  let #(_module, env) = helpers.ok_module_typecheck("type Priv = Int")

  assert dict.get(env.custom_types, "Priv")
    == Ok(types.TypeAlias([], types.IntType))
  assert set.contains(env.public_custom_types, "Priv") == False
}

pub fn alias_in_function_param_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "type Age = Int
    fn adult(age: Age) -> Bool { age >= 18 }",
    )

  assert dict.get(env.scope.definitions, "adult")
    == Ok(types.CallableType([types.IntType], dict.new(), types.BoolType))
}
