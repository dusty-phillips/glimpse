import gleam/dict
import gleam/list
import gleam/option
import glimpse/internal/typecheck/types
import typecheck/helpers

pub fn no_field_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor
  }"
    |> helpers.ok_custom_type

  assert dict.size(env.custom_types) == 5

  assert dict.get(env.custom_types, "MyType")
    == Ok(types.CustomType(env.current_module, "MyType", [], option.None))

  assert dict.size(env.definitions) == 8

  assert dict.get(env.definitions, "MyTypeConstructor")
    == Ok(types.CustomType("main_module", "MyType", [], option.Some(0)))
}

pub fn single_param_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor(name: String)
  }"
    |> helpers.ok_custom_type

  assert dict.size(env.custom_types) == 5

  assert dict.get(env.custom_types, "MyType")
    == Ok(types.CustomType(env.current_module, "MyType", [], option.None))

  assert dict.size(env.definitions) == 8

  assert dict.get(env.definitions, "MyTypeConstructor")
    == Ok(types.CallableType(
      [types.StringType],
      dict.from_list([#("name", 0)]),
      types.CustomType("main_module", "MyType", [], option.Some(0)),
    ))
}

pub fn positional_variant_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor(String)
  }"
    |> helpers.ok_custom_type

  assert dict.size(env.custom_types) == 5

  assert dict.get(env.custom_types, "MyType")
    == Ok(types.CustomType(env.current_module, "MyType", [], option.None))

  assert dict.size(env.definitions) == 8

  assert dict.get(env.definitions, "MyTypeConstructor")
    == Ok(types.CallableType(
      [types.StringType],
      dict.from_list([]),
      types.CustomType("main_module", "MyType", [], option.Some(0)),
    ))
}

pub fn multi_variant_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor(name: String)
    NumberConstructor(number: Int)
  }"
    |> helpers.ok_custom_type

  assert dict.size(env.custom_types) == 5

  assert dict.get(env.custom_types, "MyType")
    == Ok(types.CustomType(env.current_module, "MyType", [], option.None))

  assert dict.size(env.definitions) == 9

  assert dict.get(env.definitions, "MyTypeConstructor")
    == Ok(types.CallableType(
      [types.StringType],
      dict.from_list([#("name", 0)]),
      types.CustomType("main_module", "MyType", [], option.Some(0)),
    ))

  assert dict.get(env.definitions, "NumberConstructor")
    == Ok(types.CallableType(
      [types.IntType],
      dict.from_list([#("number", 0)]),
      types.CustomType("main_module", "MyType", [], option.Some(1)),
    ))
}

pub fn multi_variant_no_fields_custom_type_test() {
  let env =
    "type MyType {
    C1
    C2
    C3
  }"
    |> helpers.ok_custom_type

  assert dict.size(env.custom_types) == 5

  assert dict.get(env.custom_types, "MyType")
    == Ok(types.CustomType(env.current_module, "MyType", [], option.None))

  assert dict.size(env.definitions) == 10

  use constructor_name, variant <- list.index_map(["C1", "C2", "C3"])
  assert dict.get(env.definitions, constructor_name)
    == Ok(types.CustomType("main_module", "MyType", [], option.Some(variant)))
}

pub fn recursive_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor(name: String)
    RecursiveConstructor(next: MyType)
  }"
    |> helpers.ok_custom_type

  assert dict.size(env.custom_types) == 5

  assert dict.get(env.custom_types, "MyType")
    == Ok(types.CustomType(env.current_module, "MyType", [], option.None))

  assert dict.size(env.definitions) == 9

  assert dict.get(env.definitions, "MyTypeConstructor")
    == Ok(types.CallableType(
      [types.StringType],
      dict.from_list([#("name", 0)]),
      types.CustomType("main_module", "MyType", [], option.Some(0)),
    ))

  assert dict.get(env.definitions, "RecursiveConstructor")
    == Ok(types.CallableType(
      [types.CustomType("main_module", "MyType", [], option.None)],
      dict.from_list([#("next", 0)]),
      types.CustomType("main_module", "MyType", [], option.Some(1)),
    ))
}

pub fn custom_type_from_module_test() {
  let #(_module, env) =
    "type MyType {
    MyTypeConstructor(name: String)
  }

    type MyOtherType {
      MyOtherType(name: String)
    }"
    |> helpers.ok_module_typecheck

  assert dict.size(env.custom_types) == 6

  assert dict.get(env.custom_types, "MyType")
    == Ok(types.CustomType(env.current_module, "MyType", [], option.None))

  assert dict.get(env.custom_types, "MyOtherType")
    == Ok(types.CustomType(env.current_module, "MyOtherType", [], option.None))

  assert dict.size(env.definitions) == 9

  assert dict.get(env.definitions, "MyTypeConstructor")
    == Ok(types.CallableType(
      [types.StringType],
      dict.from_list([#("name", 0)]),
      types.CustomType("main_module", "MyType", [], option.Some(0)),
    ))

  assert dict.get(env.definitions, "MyOtherType")
    == Ok(types.CallableType(
      [types.StringType],
      dict.from_list([#("name", 0)]),
      types.CustomType("main_module", "MyOtherType", [], option.Some(0)),
    ))
}
