import gleam/dict
import gleam/result
import glimpse/error
import glimpse/internal/typecheck/types.{type Type}

pub type Environment {
  Environment(definitions: dict.Dict(String, Type))
}

pub type TypeState {
  TypeState(environment: Environment, type_: Type)
}

pub type TypeCheckResult =
  Result(TypeState, error.TypeCheckError)

pub fn new() -> Environment {
  Environment(definitions: dict.new())
}

pub fn add_def(
  environment: Environment,
  name: String,
  type_: Type,
) -> Environment {
  Environment(
    // ..environment,
    definitions: dict.insert(environment.definitions, name, type_),
  )
}

pub fn lookup_type(
  environment: Environment,
  name: String,
) -> Result(Type, error.TypeCheckError) {
  dict.get(environment.definitions, name)
  |> result.replace_error(error.InvalidName(name))
}

pub fn lookup_type_out(
  environment: Environment,
  name: String,
) -> TypeCheckResult {
  lookup_type(environment, name)
  |> result.map(TypeState(environment, _))
}
