import glance
import gleam/dict
import gleam/list
import gleeunit/should
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

pub fn blank_env() -> environment.Environment {
  environment.Environment(dict.new())
}

pub fn ok_function_typecheck(definition: String) -> glance.Function {
  let function = glance_function(definition)
  typecheck.function(blank_env(), function)
  |> should.be_ok
}

pub fn error_function_typecheck(definition: String) -> error.TypeCheckError {
  let function = glance_function(definition)
  typecheck.function(blank_env(), function)
  |> should.be_error
}
