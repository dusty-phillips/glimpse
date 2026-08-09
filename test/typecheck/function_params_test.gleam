import glance
import gleam/dict
import gleam/option
import glimpse/error
import glimpse/internal/typecheck/types
import typecheck/helpers

pub fn int_param_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo(a: Int) -> Int { a }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(18, 21), "Int", option.None, []),
    )
}

pub fn int_param_operation_test() {
  let function_out =
    helpers.ok_function_typecheck("fn add(a: Int, b: Int) -> Int { a + b }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(26, 29), "Int", option.None, []),
    )
}

pub fn float_param_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo(a: Float) -> Float { a }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(20, 25), "Float", option.None, []),
    )
}

pub fn string_param_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo(a: String) -> String { a }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(21, 27), "String", option.None, []),
    )
}

pub fn incorrect_param_return_fails_test() {
  assert helpers.error_function_typecheck("fn foo(a: String) -> Nil { a }")
    == error.InvalidReturnType("foo", "String", "Nil")
}

pub fn custom_type_param_test() {
  let function_out =
    helpers.ok_function_env_typecheck(
      types.new_env("main_module")
        |> types.add_custom_type_to_env("MyType", []),
      "fn foo(my_type: MyType) -> MyType { my_type }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(27, 33), "MyType", option.None, []),
    )
}

pub fn empty_signature_definition_test() {
  let #(_, env) = helpers.ok_module_typecheck("fn foo() -> Nil {}")

  assert dict.size(env.scope.definitions) == 8

  assert dict.get(env.scope.definitions, "foo")
    == Ok(types.CallableType([], dict.from_list([]), types.NilType))
}

pub fn single_parameter_definition_test() {
  let #(_, env) = helpers.ok_module_typecheck("fn foo(a: Int) -> Nil {}")

  assert dict.size(env.scope.definitions) == 8

  assert dict.get(env.scope.definitions, "foo")
    == Ok(types.CallableType([types.IntType], dict.from_list([]), types.NilType))
}

pub fn single_parameter_labelled_definition_test() {
  let #(_, env) = helpers.ok_module_typecheck("fn foo(lab a: Int) -> Nil {}")

  assert dict.size(env.scope.definitions) == 8

  assert dict.get(env.scope.definitions, "foo")
    == Ok(types.CallableType(
      [types.IntType],
      dict.from_list([#("lab", 0)]),
      types.NilType,
    ))
}

pub fn multi_parameter_definition_test() {
  let #(_, env) =
    helpers.ok_module_typecheck("fn foo(a: Int, b: String) -> Nil {}")

  assert dict.size(env.scope.definitions) == 8

  assert dict.get(env.scope.definitions, "foo")
    == Ok(types.CallableType(
      [types.IntType, types.StringType],
      dict.from_list([]),
      types.NilType,
    ))
}

pub fn multi_parameter_labelled_definition_test() {
  let #(_, env) =
    helpers.ok_module_typecheck("fn foo(lab a: Int, lab2 b: String) -> Nil {}")

  assert dict.size(env.scope.definitions) == 8

  assert dict.get(env.scope.definitions, "foo")
    == Ok(types.CallableType(
      [types.IntType, types.StringType],
      dict.from_list([#("lab", 0), #("lab2", 1)]),
      types.NilType,
    ))
}

pub fn mixed_positional_and_labelled_definition_test() {
  let #(_, env) =
    helpers.ok_module_typecheck("fn foo(a: Int, lab b: String) -> Nil {}")

  assert dict.size(env.scope.definitions) == 8

  assert dict.get(env.scope.definitions, "foo")
    == Ok(types.CallableType(
      [types.IntType, types.StringType],
      dict.from_list([#("lab", 1)]),
      types.NilType,
    ))
}

pub fn generic_function_parameter_test() {
  let #(_, env) = helpers.ok_module_typecheck("fn consume(x: a) -> Nil { Nil }")

  assert dict.size(env.scope.definitions) == 8
  assert dict.get(env.scope.definitions, "consume")
    == Ok(types.GenericCallableType(
      [types.GenericTypeVariable("a", False)],
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

pub fn implicit_return_type_test() {
  let #(_, env) = helpers.ok_module_typecheck("fn implicit_int() { 42 }")

  assert dict.size(env.scope.definitions) == 8
  assert dict.get(env.scope.definitions, "implicit_int")
    == Ok(types.CallableType([], dict.new(), types.IntType))
}

pub fn implicit_return_nil_test() {
  let #(_, env) = helpers.ok_module_typecheck("fn implicit_nil() { Nil }")

  assert dict.get(env.scope.definitions, "implicit_nil")
    == Ok(types.CallableType([], dict.new(), types.NilType))
}

pub fn implicit_return_with_params_test() {
  let #(_, env) = helpers.ok_module_typecheck("fn double(x: Int) { x + x }")

  assert dict.get(env.scope.definitions, "double")
    == Ok(types.CallableType([types.IntType], dict.new(), types.IntType))
}

pub fn multiple_implicit_returns_test() {
  let #(_, env) =
    helpers.ok_module_typecheck(
      "
    fn get_int() { 42 }
    fn get_string() { \"hello\" }
  ",
    )

  assert dict.size(env.scope.definitions) == 9
  assert dict.get(env.scope.definitions, "get_int")
    == Ok(types.CallableType([], dict.new(), types.IntType))
  assert dict.get(env.scope.definitions, "get_string")
    == Ok(types.CallableType([], dict.new(), types.StringType))
}
