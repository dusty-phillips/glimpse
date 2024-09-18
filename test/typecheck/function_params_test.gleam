import glance
import gleam/option
import gleeunit/should
import glimpse/error
import glimpse/internal/typecheck/environment
import glimpse/internal/typecheck/types
import typecheck/assertions
import typecheck/helpers

pub fn int_param_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo(a: Int) -> Int { a }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn int_param_operation_test() {
  let function_out =
    helpers.ok_function_typecheck("fn add(a: Int, b: Int) -> Int { a + b }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn float_param_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo(a: Float) -> Float { a }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Float", option.None, [])))
}

pub fn string_param_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo(a: String) -> String { a }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("String", option.None, [])))
}

pub fn incorrect_param_return_fails_test() {
  helpers.error_function_typecheck("fn foo(a: String) -> Nil { a }")
  |> should.equal(error.InvalidReturnType("foo", "String", "Nil"))
}

pub fn custom_type_param_test() {
  let function_out =
    helpers.ok_function_env_typecheck(
      environment.new("main_module") |> environment.add_custom_type("MyType"),
      "fn foo(my_type: MyType) -> MyType { my_type }",
    )

  function_out.return
  |> should.equal(option.Some(glance.NamedType("MyType", option.None, [])))
}

pub fn empty_signature_definition_test() {
  let #(_, env) = helpers.ok_module_typecheck("fn foo() -> Nil {}")

  assertions.should_have_dict_size(env.definitions, 1)

  assertions.should_be_callable(env, "foo", [], [], types.NilType)
}

pub fn single_parameter_definition_test() {
  let #(_, env) = helpers.ok_module_typecheck("fn foo(a: Int) -> Nil {}")

  assertions.should_have_dict_size(env.definitions, 1)

  assertions.should_be_callable(env, "foo", [types.IntType], [], types.NilType)
}

pub fn single_parameter_labelled_definition_test() {
  let #(_, env) = helpers.ok_module_typecheck("fn foo(lab a: Int) -> Nil {}")

  assertions.should_have_dict_size(env.definitions, 1)

  assertions.should_be_callable(
    env,
    "foo",
    [types.IntType],
    [#("lab", 0)],
    types.NilType,
  )
}

pub fn multi_parameter_definition_test() {
  let #(_, env) =
    helpers.ok_module_typecheck("fn foo(a: Int, b: String) -> Nil {}")

  assertions.should_have_dict_size(env.definitions, 1)

  assertions.should_be_callable(
    env,
    "foo",
    [types.IntType, types.StringType],
    [],
    types.NilType,
  )
}

pub fn multi_parameter_labelled_definition_test() {
  let #(_, env) =
    helpers.ok_module_typecheck("fn foo(lab a: Int, lab2 b: String) -> Nil {}")

  assertions.should_have_dict_size(env.definitions, 1)

  assertions.should_be_callable(
    env,
    "foo",
    [types.IntType, types.StringType],
    [#("lab", 0), #("lab2", 1)],
    types.NilType,
  )
}

pub fn mixed_positional_and_labelled_definition_test() {
  let #(_, env) =
    helpers.ok_module_typecheck("fn foo(a: Int, lab b: String) -> Nil {}")

  assertions.should_have_dict_size(env.definitions, 1)

  assertions.should_be_callable(
    env,
    "foo",
    [types.IntType, types.StringType],
    [#("lab", 1)],
    types.NilType,
  )
}
