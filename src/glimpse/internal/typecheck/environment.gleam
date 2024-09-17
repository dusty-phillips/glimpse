import glance
import gleam/dict
import gleam/option
import gleam/result
import glimpse/error
import glimpse/internal/typecheck/types.{type Type, type TypeResult}
import pprint

pub type Environment {
  Environment(
    definitions: dict.Dict(String, Type),
    custom_types: dict.Dict(String, Type),
    module_environments: dict.Dict(String, Environment),
  )
}

pub type EnvState(a) {
  EnvState(environment: Environment, state: a)
}

pub type EnvStateResult(a) =
  error.TypeCheckResult(EnvState(a))

pub type EnvStateFold(a) =
  error.TypeCheckFold(EnvState(a))

pub type TypeState =
  EnvState(Type)

pub type TypeStateFold =
  error.TypeCheckFold(TypeState)

pub type TypeStateResult =
  error.TypeCheckResult(TypeState)

pub type EnvironmentResult =
  error.TypeCheckResult(Environment)

pub type EnvironmentFold =
  error.TypeCheckFold(Environment)

pub fn new() -> Environment {
  Environment(
    definitions: dict.new(),
    custom_types: dict.new(),
    module_environments: dict.new(),
  )
}

pub fn add_def(
  environment: Environment,
  name: String,
  type_: Type,
) -> Environment {
  Environment(
    ..environment,
    definitions: dict.insert(environment.definitions, name, type_),
  )
}

pub fn add_custom_type(environment: Environment, name: String) -> Environment {
  Environment(
    ..environment,
    custom_types: dict.insert(
      environment.custom_types,
      name,
      types.CustomType(name),
    ),
  )
}

pub fn lookup_variable_type(
  environment: Environment,
  name: String,
) -> TypeResult {
  dict.get(environment.definitions, name)
  |> result.replace_error(error.InvalidName(name))
}

pub fn lookup_custom_type(environment: Environment, name: String) -> TypeResult {
  dict.get(environment.custom_types, name)
  |> result.replace_error(error.UnknownCustomType(name))
}

pub fn extract_env(state: EnvState(a)) -> Environment {
  state.environment
}

pub fn type_(environment: Environment, glance_type: glance.Type) -> TypeResult {
  case glance_type {
    glance.NamedType("Int", option.None, []) -> Ok(types.IntType)
    glance.NamedType("Float", option.None, []) -> Ok(types.FloatType)
    glance.NamedType("Nil", option.None, []) -> Ok(types.NilType)
    glance.NamedType("String", option.None, []) -> Ok(types.StringType)
    glance.NamedType("Bool", option.None, []) -> Ok(types.BoolType)

    // TODO: custom types with parameters need to be supported
    // TODO: not 100% certain all named types that are not covered
    // above are actually custom types
    // TODO: support named types in other modules
    glance.NamedType(name, option.None, []) ->
      lookup_custom_type(environment, name)

    glance.VariableType(name) -> lookup_variable_type(environment, name)
    _ -> {
      pprint.debug(glance_type)
      todo
    }
  }
}
