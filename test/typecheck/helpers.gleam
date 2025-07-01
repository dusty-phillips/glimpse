import glance
import gleam/dict
import gleam/list
import glimpse
import glimpse/error
import glimpse/internal/typecheck/types.{type Environment}
import glimpse/typecheck

pub fn glance_custom_type(definition: String) -> glance.CustomType {
  let assert Ok(module) = glance.module(definition)

  assert list.length(module.custom_types) == 1

  let assert Ok(definition) = list.first(module.custom_types)

  definition.definition
}

pub fn ok_custom_type(definition: String) -> Environment {
  let assert Ok(result) =
    typecheck.custom_type(
      types.new_env("main_module"),
      glance_custom_type(definition),
    )
  result
}

pub fn glance_function(definition: String) -> glance.Function {
  let assert Ok(module) = glance.module(definition)

  assert list.length(module.functions) == 1

  let assert Ok(definition) = list.first(module.functions)
  definition.definition
}

pub fn ok_function_env_typecheck(
  env: Environment,
  definition: String,
) -> glance.Function {
  let function = glance_function(definition)
  let assert Ok(types.EnvState(_, updated_function)) =
    typecheck.function(env, function)
  updated_function
}

pub fn ok_function_typecheck(definition: String) -> glance.Function {
  ok_function_env_typecheck(types.new_env("main_module"), definition)
}

pub fn error_function_typecheck(definition: String) -> error.TypeCheckError {
  let function = glance_function(definition)
  let assert Error(error) =
    typecheck.function(types.new_env("main_module"), function)
  error
}

pub fn ok_module_typecheck(definition: String) -> #(glimpse.Module, Environment) {
  let assert Ok(module) = glance.module(definition)
  let assert Ok(result) =
    typecheck.module(glimpse.Module("main_module", module, []), dict.new())
  result
}

pub fn error_module_typecheck(definition: String) -> error.TypeCheckError {
  let assert Ok(module) = glance.module(definition)
  let assert Error(error) =
    typecheck.module(glimpse.Module("main_module", module, []), dict.new())
  error
}

pub fn ok_package_check(
  main_module: String,
  loader: fn(String) -> Result(String, Nil),
) -> glimpse.Package {
  let assert Ok(package) = glimpse.load_package(main_module, loader)
  let assert Ok(result) = typecheck.package(package)
  result
}
