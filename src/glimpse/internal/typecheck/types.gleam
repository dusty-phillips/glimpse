import glance
import gleam/dict.{type Dict}
import gleam/iterator
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string_builder
import glimpse/error
import pprint

pub type Type {
  NilType
  IntType
  FloatType
  StringType
  BoolType
  CustomType(module: String, name: String)
  CallableType(
    /// All parameters (labelled or otherwise)
    parameters: List(Type),
    /// Map of label to its position in parameters list
    position_labels: Dict(String, Int),
    return: Type,
  )
  /// Used for field access on imports; no direct glance analog
  NamespaceType(Dict(String, Type))
}

pub type TypeResult =
  error.TypeCheckResult(Type)

pub type Environment {
  Environment(
    // Full absolute path. Used to identify and construct custom types
    current_module: String,
    definitions: dict.Dict(String, Type),
    public_definitions: set.Set(String),
    custom_types: dict.Dict(String, Type),
    // absolute path to whatever the relative name is in this env
    import_names: dict.Dict(String, String),
    // other environments that could be imported from this one
    // (actually imported envs will be in definitions)
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

pub fn new_env(current_module: String) -> Environment {
  Environment(
    current_module:,
    definitions: dict.new(),
    public_definitions: set.new(),
    custom_types: dict.new(),
    import_names: dict.new(),
    module_environments: dict.new(),
  )
}

pub fn add_def_to_env(
  environment: Environment,
  name: String,
  type_: Type,
) -> Environment {
  Environment(
    ..environment,
    definitions: dict.insert(environment.definitions, name, type_),
  )
}

/// publish a name that is already in the definitions so that it is
/// visible to importing modules
pub fn publish_def_in_env(environment: Environment, name: String) -> Environment {
  Environment(
    ..environment,
    public_definitions: set.insert(environment.public_definitions, name),
  )
}

/// Adds the custom_type to the environment, assuming that the current module
//

pub fn add_custom_type_to_env(
  environment: Environment,
  name: String,
) -> Environment {
  Environment(
    ..environment,
    custom_types: dict.insert(
      environment.custom_types,
      name,
      CustomType(environment.current_module, name),
    ),
  )
}

pub fn add_import_mapping_to_env(
  environment: Environment,
  absolute_name: String,
  relative_name: String,
) -> Environment {
  Environment(
    ..environment,
    import_names: dict.insert(
      environment.import_names,
      absolute_name,
      relative_name,
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
    glance.NamedType("Int", option.None, []) -> Ok(IntType)
    glance.NamedType("Float", option.None, []) -> Ok(FloatType)
    glance.NamedType("Nil", option.None, []) -> Ok(NilType)
    glance.NamedType("String", option.None, []) -> Ok(StringType)
    glance.NamedType("Bool", option.None, []) -> Ok(BoolType)

    // TODO: custom types with parameters need to be supported
    // TODO: not 100% certain all named types that are not covered
    // above are actually custom types
    // TODO: support named types in other modules
    glance.NamedType(name, option.None, []) ->
      lookup_custom_type(environment, name)

    glance.VariableType(name) -> lookup_variable_type(environment, name)
    _ -> {
      pprint.debug(glance_type)
      todo as "many glance types not processed yet"
    }
  }
}

pub fn to_string(environment: Environment, type_: Type) -> String {
  case type_ {
    NilType -> "Nil"
    IntType -> "Int"
    FloatType -> "Float"
    StringType -> "String"
    BoolType -> "Bool"
    CustomType(_module, name) -> name
    CallableType(parameters, _labels, return) ->
      string_builder.from_string("fn (")
      |> string_builder.append(list_to_string(parameters, environment))
      |> string_builder.append(") -> ")
      |> string_builder.append(to_string(environment, return))
      |> string_builder.to_string
    NamespaceType(_) -> "<Namespace>"
  }
}

pub fn list_to_string(types: List(Type), environment: Environment) -> String {
  types
  |> iterator.from_list
  |> iterator.map(to_string(environment, _))
  |> iterator.map(string_builder.from_string)
  |> iterator.to_list
  |> string_builder.join(", ")
  |> string_builder.to_string
}

pub fn to_glance(environment: Environment, type_: Type) -> glance.Type {
  case type_ {
    NilType -> glance.NamedType("Nil", option.None, [])
    IntType -> glance.NamedType("Int", option.None, [])
    FloatType -> glance.NamedType("Float", option.None, [])
    StringType -> glance.NamedType("String", option.None, [])
    BoolType -> glance.NamedType("Bool", option.None, [])
    CustomType(_module, name) -> glance.NamedType(name, option.None, [])
    CallableType(parameters, _labels, return) ->
      glance.FunctionType(
        list.map(parameters, to_glance(environment, _)),
        to_glance(environment, return),
      )
    NamespaceType(_) -> panic as "Cannot convert namespace to glance"
  }
}

pub fn to_binop_error(
  environment: Environment,
  operator: String,
  left: Type,
  right: Type,
  expected: String,
) -> TypeResult {
  Error(error.InvalidBinOp(
    operator,
    to_string(environment, left),
    to_string(environment, right),
    expected,
  ))
}
