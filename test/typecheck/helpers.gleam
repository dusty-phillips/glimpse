import glance
import gleam/dict
import gleam/list
import gleeunit/should
import glimpse
import glimpse/error
import glimpse/internal/typecheck/environment
import glimpse/typecheck

// Helpers
pub fn glance_function(definition: String) -> glance.Function {
  let module =
    glance.module(definition)
    |> should.be_ok()

  module.functions |> list.length |> should.equal(1)

  let definition = list.first(module.functions) |> should.be_ok()
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

pub fn ok_module_typecheck(definition: String) -> glimpse.Module {
  let inferred_package =
    glimpse.load_package("main_module", fn(_) { Ok(definition) })
    |> should.be_ok
    |> typecheck.module("main_module")
    |> should.be_ok

  inferred_package.modules
  |> dict.get("main_module")
  |> should.be_ok
}

pub fn error_module_typecheck(definition: String) -> error.TypeCheckError {
  glimpse.load_package("main_module", fn(_) { Ok(definition) })
  |> should.be_ok
  |> typecheck.module("main_module")
  |> should.be_error
}
