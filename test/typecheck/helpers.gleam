import glance
import gleam/dict
import gleam/list
import gleeunit/should
import glimpse
import glimpse/error
import glimpse/internal/typecheck/types.{type Environment}
import glimpse/typecheck
import typecheck/assertions

pub fn glance_custom_type(definition: String) -> glance.CustomType {
  let module =
    glance.module(definition)
    |> should.be_ok

  assertions.should_have_list_length(module.custom_types, 1)

  let definition =
    list.first(module.custom_types)
    |> should.be_ok

  definition.definition
}

pub fn ok_custom_type(definition: String) -> Environment {
  glance_custom_type(definition)
  |> typecheck.custom_type(types.new_env("main_module"), _)
  |> should.be_ok
}

pub fn glance_function(definition: String) -> glance.Function {
  let module =
    glance.module(definition)
    |> should.be_ok

  assertions.should_have_list_length(module.functions, 1)

  let definition = list.first(module.functions) |> should.be_ok
  definition.definition
}

pub fn ok_function_env_typecheck(
  env: Environment,
  definition: String,
) -> glance.Function {
  let function = glance_function(definition)
  typecheck.function(env, function)
  |> should.be_ok
}

pub fn ok_function_typecheck(definition: String) -> glance.Function {
  ok_function_env_typecheck(types.new_env("main_module"), definition)
}

pub fn error_function_typecheck(definition: String) -> error.TypeCheckError {
  let function = glance_function(definition)
  typecheck.function(types.new_env("main_module"), function)
  |> should.be_error
}

pub fn ok_module_typecheck(definition: String) -> #(glimpse.Module, Environment) {
  glance.module(definition)
  |> should.be_ok
  |> glimpse.Module("main_module", _, [])
  |> typecheck.module(dict.new())
  |> should.be_ok
}

pub fn error_module_typecheck(definition: String) -> error.TypeCheckError {
  glance.module(definition)
  |> should.be_ok
  |> glimpse.Module("main_module", _, [])
  |> typecheck.module(dict.new())
  |> should.be_error
}

pub fn ok_package_check(
  main_module: String,
  loader: fn(String) -> Result(String, Nil),
) -> glimpse.Package {
  glimpse.load_package(main_module, loader)
  |> should.be_ok
  |> typecheck.package
  |> should.be_ok
}
