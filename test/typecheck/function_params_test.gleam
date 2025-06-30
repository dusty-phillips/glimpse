import glance
import gleam/dict
import gleam/option
import gleeunit/should
import glimpse/error
import glimpse/internal/typecheck/types
import typecheck/assertions
import typecheck/helpers

pub fn int_param_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo(a: Int) -> Int { a }")

  function_out.return
  |> should.equal(
    option.Some(glance.NamedType(glance.Span(18, 21), "Int", option.None, [])),
  )
}

pub fn int_param_operation_test() {
  let function_out =
    helpers.ok_function_typecheck("fn add(a: Int, b: Int) -> Int { a + b }")

  function_out.return
  |> should.equal(
    option.Some(glance.NamedType(glance.Span(26, 29), "Int", option.None, [])),
  )
}

pub fn float_param_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo(a: Float) -> Float { a }")

  function_out.return
  |> should.equal(
    option.Some(glance.NamedType(glance.Span(20, 25), "Float", option.None, [])),
  )
}

pub fn string_param_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo(a: String) -> String { a }")

  function_out.return
  |> should.equal(
    option.Some(
      glance.NamedType(glance.Span(21, 27), "String", option.None, []),
    ),
  )
}

pub fn incorrect_param_return_fails_test() {
  helpers.error_function_typecheck("fn foo(a: String) -> Nil { a }")
  |> should.equal(error.InvalidReturnType("foo", "String", "Nil"))
}

pub fn custom_type_param_test() {
  let function_out =
    helpers.ok_function_env_typecheck(
      types.new_env("main_module") |> types.add_custom_type_to_env("MyType"),
      "fn foo(my_type: MyType) -> MyType { my_type }",
    )

  function_out.return
  |> should.equal(
    option.Some(
      glance.NamedType(glance.Span(27, 33), "MyType", option.None, []),
    ),
  )
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

pub fn generic_function_parameter_test() {
  let #(_, env) = helpers.ok_module_typecheck("fn consume(x: a) -> Nil { Nil }")

  assertions.should_have_dict_size(env.definitions, 1)
  assert dict.get(env.definitions, "consume")
    == Ok(types.GenericCallableType(
      [types.GenericTypeVariable("a")],
      dict.new(),
      types.NilType,
      glance.Function(
        glance.Span(0, 31),
        "consume",
        glance.Private,
        [
          glance.FunctionParameter(
            option.None,
            glance.Named("x"),
            option.Some(glance.VariableType(glance.Span(14, 15), "a")),
          ),
        ],
        option.Some(
          glance.NamedType(glance.Span(20, 23), "Nil", option.None, []),
        ),
        [glance.Expression(glance.Variable(glance.Span(26, 29), "Nil"))],
      ),
    ))
}
