import glance
import gleam/dict
import gleam/list
import gleam/option
import glimpse/error
import glimpse/internal/typecheck/types
import typecheck/helpers

const unknown_span = glance.Span(-1, -1)

pub fn private_function_unannotated_param_test() {
  let #(module, env) = helpers.ok_module_typecheck("fn double(x) { x * 2 }")

  assert dict.get(env.definitions, "double")
    == Ok(types.CallableType([types.IntType], dict.new(), types.IntType))

  let assert [double_def] = module.module.functions
  assert double_def.definition.parameters
    == [
      glance.FunctionParameter(
        option.None,
        glance.Named("x"),
        option.Some(glance.NamedType(unknown_span, "Int", option.None, [])),
      ),
    ]
  assert double_def.definition.return
    == option.Some(glance.NamedType(unknown_span, "Int", option.None, []))
}

pub fn private_function_multiple_unannotated_params_test() {
  let #(module, env) = helpers.ok_module_typecheck("fn add(x, y) { x + y }")

  assert dict.get(env.definitions, "add")
    == Ok(types.CallableType(
      [types.IntType, types.IntType],
      dict.new(),
      types.IntType,
    ))

  let assert [add_def] = module.module.functions
  assert add_def.definition.parameters
    == [
      glance.FunctionParameter(
        option.None,
        glance.Named("x"),
        option.Some(glance.NamedType(unknown_span, "Int", option.None, [])),
      ),
      glance.FunctionParameter(
        option.None,
        glance.Named("y"),
        option.Some(glance.NamedType(unknown_span, "Int", option.None, [])),
      ),
    ]
  assert add_def.definition.return
    == option.Some(glance.NamedType(unknown_span, "Int", option.None, []))
}

pub fn private_function_mixed_annotated_unannotated_test() {
  let #(module, env) =
    helpers.ok_module_typecheck("fn foo(x: Int, y) { x + y }")

  assert dict.get(env.definitions, "foo")
    == Ok(types.CallableType(
      [types.IntType, types.IntType],
      dict.new(),
      types.IntType,
    ))

  let assert [foo_def] = module.module.functions
  // Check parameter types (annotated params keep their spans, inferred get unknown_span)
  let params = foo_def.definition.parameters
  assert list.length(params) == 2
  assert params
    |> list.map(fn(p) {
      case p {
        glance.FunctionParameter(
          _,
          glance.Named(name),
          option.Some(glance.NamedType(_, type_name, _, _)),
        ) -> #(name, type_name)
        _ -> #("", "")
      }
    })
    == [#("x", "Int"), #("y", "Int")]
}

pub fn private_function_generic_inference_test() {
  let #(module, env) = helpers.ok_module_typecheck("fn id(x) { x }")

  // Check the type signature in the environment
  let id_type = dict.get(env.definitions, "id")
  let assert Ok(apply_type) = id_type
  let assert types.GenericCallableType(_, _, _, _) = apply_type

  // Check the function AST has correct parameter and return types (spans may vary)
  let assert [id_def] = module.module.functions
  let params = id_def.definition.parameters
  assert list.length(params) == 1
  let param_ok = case params {
    [
      glance.FunctionParameter(
        _,
        glance.Named("x"),
        option.Some(glance.VariableType(_, "a")),
      ),
    ] -> True
    _ -> False
  }
  assert param_ok
  let return_ok = case id_def.definition.return {
    option.Some(glance.VariableType(_, "a")) -> True
    _ -> False
  }
  assert return_ok
}

pub fn private_function_generic_multiple_params_test() {
  let #(module, env) = helpers.ok_module_typecheck("fn pair(x, y) { #(x, y) }")

  let pair_type = dict.get(env.definitions, "pair")
  let assert Ok(types.GenericCallableType(parameters, labels, return_, _)) =
    pair_type
  assert parameters
    == [types.GenericTypeVariable("a"), types.GenericTypeVariable("b")]
  assert labels == dict.new()
  assert return_
    == types.TupleType([
      types.GenericTypeVariable("a"),
      types.GenericTypeVariable("b"),
    ])

  let assert [pair_def] = module.module.functions
  let params_ok = case pair_def.definition.parameters {
    [
      glance.FunctionParameter(
        option.None,
        glance.Named("x"),
        option.Some(glance.VariableType(_, "a")),
      ),
      glance.FunctionParameter(
        option.None,
        glance.Named("y"),
        option.Some(glance.VariableType(_, "b")),
      ),
    ] -> True
    _ -> False
  }
  assert params_ok
  let return_ok = case pair_def.definition.return {
    option.Some(glance.TupleType(
      _,
      [glance.VariableType(_, "a"), glance.VariableType(_, "b")],
    )) -> True
    _ -> False
  }
  assert return_ok
}

pub fn private_function_discard_param_test() {
  let #(module, env) = helpers.ok_module_typecheck("fn foo(_) { 1 }")

  let foo_type = dict.get(env.definitions, "foo")
  let assert Ok(types.GenericCallableType(parameters, labels, return_, _)) =
    foo_type
  assert parameters == [types.GenericTypeVariable("a")]
  assert labels == dict.new()
  assert return_ == types.IntType

  let assert [foo_def] = module.module.functions
  let param_ok = case foo_def.definition.parameters {
    [
      glance.FunctionParameter(
        option.None,
        glance.Discarded(_),
        option.Some(glance.VariableType(_, "a")),
      ),
    ] -> True
    _ -> False
  }
  assert param_ok
  let return_ok = case foo_def.definition.return {
    option.Some(glance.NamedType(_, "Int", option.None, [])) -> True
    _ -> False
  }
  assert return_ok
}

pub fn private_function_recursive_inference_test() {
  let #(module, env) =
    helpers.ok_module_typecheck(
      "
      fn fact(n) {
        case n {
          0 -> 1
          _ -> n * fact(n - 1)
        }
      }",
    )

  assert dict.get(env.definitions, "fact")
    == Ok(types.CallableType([types.IntType], dict.new(), types.IntType))

  let assert [fact_def] = module.module.functions
  assert fact_def.definition.parameters
    == [
      glance.FunctionParameter(
        option.None,
        glance.Named("n"),
        option.Some(glance.NamedType(unknown_span, "Int", option.None, [])),
      ),
    ]
  assert fact_def.definition.return
    == option.Some(glance.NamedType(unknown_span, "Int", option.None, []))
}

pub fn private_function_unannotated_string_ops_test() {
  let #(module, env) =
    helpers.ok_module_typecheck("fn greet(name) { \"Hello, \" <> name }")

  assert dict.get(env.definitions, "greet")
    == Ok(types.CallableType([types.StringType], dict.new(), types.StringType))

  let assert [greet_def] = module.module.functions
  assert greet_def.definition.parameters
    == [
      glance.FunctionParameter(
        option.None,
        glance.Named("name"),
        option.Some(glance.NamedType(unknown_span, "String", option.None, [])),
      ),
    ]
}

pub fn private_function_unannotated_bool_ops_test() {
  let #(_module, env) = helpers.ok_module_typecheck("fn not_it(b) { !b }")

  assert dict.get(env.definitions, "not_it")
    == Ok(types.CallableType([types.BoolType], dict.new(), types.BoolType))
}

pub fn private_function_unannotated_float_ops_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck("fn double_it(f) { f *. 2.0 }")

  assert dict.get(env.definitions, "double_it")
    == Ok(types.CallableType([types.FloatType], dict.new(), types.FloatType))
}

pub fn public_function_requires_annotation_test() {
  assert helpers.error_module_typecheck("pub fn add(x, y) { x + y }")
    == error.MissingParameterAnnotation("x")
}

pub fn public_function_mixed_requires_annotation_test() {
  assert helpers.error_module_typecheck("pub fn foo(x: Int, y) { x + y }")
    == error.MissingParameterAnnotation("y")
}

pub fn private_function_unannotated_then_used_polymorphically_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "
      fn id(x) { x }
      fn use_id() {
        id(1)
        id(\"hello\")
      }",
    )

  // id should be generic
  let id_type = dict.get(env.definitions, "id")
  let assert Ok(apply_type) = id_type
  let assert types.GenericCallableType(
    [types.GenericTypeVariable("a")],
    _labels,
    types.GenericTypeVariable("a"),
    _original,
  ) = apply_type

  // use_id should typecheck - its return type is String (last expression)
  assert dict.get(env.definitions, "use_id")
    == Ok(types.CallableType([], dict.new(), types.StringType))
}

pub fn private_function_calls_inferred_function_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "
      fn add(x, y) { x + y }
      fn use_add() { add(1, 2) }
      ",
    )

  // add should be Int, Int -> Int
  assert dict.get(env.definitions, "add")
    == Ok(types.CallableType(
      [types.IntType, types.IntType],
      dict.new(),
      types.IntType,
    ))

  // use_add should be Int (result of add(1, 2))
  assert dict.get(env.definitions, "use_add")
    == Ok(types.CallableType([], dict.new(), types.IntType))
}
