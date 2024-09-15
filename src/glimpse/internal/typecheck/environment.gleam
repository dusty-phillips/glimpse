import gleam/dict
import gleam/result
import glimpse/error
import glimpse/internal/typecheck/types.{type Type, type TypeResult}
import glimpse/internal/typecheck/variants.{type Variant}

pub type Environment {
  Environment(
    definitions: dict.Dict(String, Type),
    custom_types: dict.Dict(String, Type),
    constructors: dict.Dict(String, Variant),
  )
}

pub type TypeState {
  TypeState(environment: Environment, type_: Type)
}

pub type TypeCheckResult =
  Result(TypeState, error.TypeCheckError)

pub fn new() -> Environment {
  Environment(
    definitions: dict.new(),
    custom_types: dict.new(),
    constructors: dict.new(),
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

pub fn add_variant_constructor(
  environment: Environment,
  name: String,
  constructor: Variant,
) -> Environment {
  Environment(
    ..environment,
    constructors: dict.insert(environment.constructors, name, constructor),
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

pub fn extract_env(state: TypeState) -> Environment {
  state.environment
}
