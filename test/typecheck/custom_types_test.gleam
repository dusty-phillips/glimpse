import gleam/list
import glimpse/internal/typecheck/types
import typecheck/assertions
import typecheck/helpers

pub fn no_field_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor
  }"
    |> helpers.ok_custom_type

  assertions.should_have_dict_size(env.custom_types, 1)

  assertions.should_have_type(env, "MyType")

  assertions.should_have_dict_size(env.definitions, 1)

  assertions.should_be_callable(
    env,
    "MyTypeConstructor",
    [],
    [],
    types.CustomType("main_module", "MyType"),
  )
}

pub fn single_param_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor(name: String)
  }"
    |> helpers.ok_custom_type

  assertions.should_have_dict_size(env.custom_types, 1)

  assertions.should_have_type(env, "MyType")

  assertions.should_have_dict_size(env.definitions, 1)

  assertions.should_be_callable(
    env,
    "MyTypeConstructor",
    [types.StringType],
    [#("name", 0)],
    types.CustomType("main_module", "MyType"),
  )
}

pub fn positional_variant_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor(String)
  }"
    |> helpers.ok_custom_type

  assertions.should_have_dict_size(env.custom_types, 1)

  assertions.should_have_type(env, "MyType")

  assertions.should_have_dict_size(env.definitions, 1)

  assertions.should_be_callable(
    env,
    "MyTypeConstructor",
    [types.StringType],
    [],
    types.CustomType("main_module", "MyType"),
  )
}

pub fn multi_variant_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor(name: String)
    NumberConstructor(number: Int)
  }"
    |> helpers.ok_custom_type

  assertions.should_have_dict_size(env.custom_types, 1)

  assertions.should_have_type(env, "MyType")

  assertions.should_have_dict_size(env.definitions, 2)

  assertions.should_be_callable(
    env,
    "MyTypeConstructor",
    [types.StringType],
    [#("name", 0)],
    types.CustomType("main_module", "MyType"),
  )

  assertions.should_be_callable(
    env,
    "NumberConstructor",
    [types.IntType],
    [#("number", 0)],
    types.CustomType("main_module", "MyType"),
  )
}

pub fn multi_variant_no_fields_custom_type_test() {
  let env =
    "type MyType {
    C1
    C2
    C3
  }"
    |> helpers.ok_custom_type

  assertions.should_have_dict_size(env.custom_types, 1)

  assertions.should_have_type(env, "MyType")

  assertions.should_have_dict_size(env.definitions, 3)

  use constructor_name <- list.each(["C1", "C2", "C3"])
  assertions.should_be_callable(
    env,
    constructor_name,
    [],
    [],
    types.CustomType("main_module", "MyType"),
  )
}

pub fn recursive_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor(name: String)
    RecursiveConstructor(next: MyType)
  }"
    |> helpers.ok_custom_type

  assertions.should_have_dict_size(env.custom_types, 1)

  assertions.should_have_type(env, "MyType")

  assertions.should_have_dict_size(env.definitions, 2)

  assertions.should_be_callable(
    env,
    "MyTypeConstructor",
    [types.StringType],
    [#("name", 0)],
    types.CustomType("main_module", "MyType"),
  )

  assertions.should_be_callable(
    env,
    "RecursiveConstructor",
    [types.CustomType("main_module", "MyType")],
    [#("next", 0)],
    types.CustomType("main_module", "MyType"),
  )
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

  assertions.should_have_dict_size(env.custom_types, 2)

  assertions.should_have_type(env, "MyType")

  assertions.should_have_type(env, "MyOtherType")

  assertions.should_have_dict_size(env.definitions, 2)

  assertions.should_be_callable(
    env,
    "MyTypeConstructor",
    [types.StringType],
    [#("name", 0)],
    types.CustomType("main_module", "MyType"),
  )

  assertions.should_be_callable(
    env,
    "MyOtherType",
    [types.StringType],
    [#("name", 0)],
    types.CustomType("main_module", "MyOtherType"),
  )
}
