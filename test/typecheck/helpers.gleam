import glance
import gleam/dict
import gleam/list
import gleeunit/should
import glimpse
import glimpse/error
import glimpse/internal/typecheck/environment.{type Environment}
import glimpse/typecheck

pub fn glance_custom_type(definition: String) -> glance.CustomType {
  let module =
    glance.module(definition)
    |> should.be_ok

  module.custom_types |> list.length |> should.equal(1)

  let definition =
    list.first(module.custom_types)
    |> should.be_ok

  definition.definition
}

pub fn ok_custom_type(definition: String) -> environment.Environment {
  glance_custom_type(definition)
  |> typecheck.custom_type(environment.new(), _)
  |> should.be_ok
}

pub fn glance_function(definition: String) -> glance.Function {
  let module =
    glance.module(definition)
    |> should.be_ok

  module.functions |> list.length |> should.equal(1)

  let definition = list.first(module.functions) |> should.be_ok
  definition.definition
}

pub fn ok_function_typecheck(definition: String) -> glance.Function {
  let function = glance_function(definition)
  typecheck.function(environment.new(), function)
  |> should.be_ok
}

pub fn error_function_typecheck(definition: String) -> error.TypeCheckError {
  let function = glance_function(definition)
  typecheck.function(environment.new(), function)
  |> should.be_error
}

pub fn ok_module_typecheck(definition: String) -> #(glimpse.Module, Environment) {
  let #(inferred_package, environment) =
    glimpse.load_package("main_module", fn(_) { Ok(definition) })
    |> should.be_ok
    |> typecheck.module("main_module")
    |> should.be_ok

  let main_mod =
    inferred_package.modules
    |> dict.get("main_module")
    |> should.be_ok

  #(main_mod, environment)
}

pub fn error_module_typecheck(definition: String) -> error.TypeCheckError {
  glimpse.load_package("main_module", fn(_) { Ok(definition) })
  |> should.be_ok
  |> typecheck.module("main_module")
  |> should.be_error
}
