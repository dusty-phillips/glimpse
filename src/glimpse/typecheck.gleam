import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import glimpse
import glimpse/error
import pprint

pub type Type {
  NilType
  IntType
  FloatType
  StringType
}

pub type Environment {
  Environment(definitions: dict.Dict(String, Type))
}

pub type TypeOut {
  TypeOut(environment: Environment, type_: Type)
}

type TypeCheckResult =
  Result(TypeOut, error.TypeCheckError)

pub fn to_string(type_: Type) -> String {
  case type_ {
    NilType -> "Nil"
    IntType -> "Int"
    FloatType -> "Float"
    StringType -> "String"
  }
}

pub fn to_glance(type_: Type) -> glance.Type {
  case type_ {
    NilType -> glance.NamedType("Nil", option.None, [])
    IntType -> glance.NamedType("Int", option.None, [])
    FloatType -> glance.NamedType("Float", option.None, [])
    StringType -> glance.NamedType("String", option.None, [])
  }
}

pub fn module(
  package: glimpse.Package,
  module_name: String,
) -> Result(Nil, error.TypeCheckError) {
  todo
}

/// Takes a glance function as input and returns the same function, but
/// with the inferred return type if the original function did not have
/// a return type. Returns an error if anything in the function doesn't
/// typecheck.
pub fn function(
  environment: Environment,
  function: glance.Function,
) -> Result(glance.Function, error.TypeCheckError) {
  use environment <- result.try(list.fold_until(
    function.parameters,
    Ok(environment),
    fold_function_parameter,
  ))

  case block(environment, function.body) {
    Error(err) -> Error(err)
    Ok(block_out) ->
      case function.return {
        option.None -> {
          Ok(
            glance.Function(
              ..function,
              return: option.Some(to_glance(block_out.type_)),
            ),
          )
        }
        option.Some(expected_type) -> {
          case type_(environment, expected_type) {
            Error(err) -> Error(err)
            Ok(expected) if expected != block_out.type_ ->
              Error(error.InvalidReturnType(
                function.name,
                block_out.type_ |> to_string,
                expected |> to_string,
              ))
            Ok(_) -> Ok(function)
          }
        }
      }
  }
}

fn fold_function_parameter(
  state: Result(Environment, error.TypeCheckError),
  param: glance.FunctionParameter,
) -> list.ContinueOrStop(Result(Environment, error.TypeCheckError)) {
  case state {
    Error(_err) -> list.Stop(state)
    Ok(environment) ->
      {
        case param {
          glance.FunctionParameter(name: glance.Discarded(_), ..) ->
            Ok(environment)
          glance.FunctionParameter(type_: option.None, ..) ->
            todo as "Not inferring untyped parameters yet"
          glance.FunctionParameter(
            name: glance.Named(name),
            type_: option.Some(glance_type),
            ..,
          ) -> {
            use check_type <- result.try(type_(environment, glance_type))
            Ok(add_def(environment, name, check_type))
          }
        }
      }
      |> list.Continue
  }
}

pub fn block(
  environment: Environment,
  statements: List(glance.Statement),
) -> TypeCheckResult {
  list.fold_until(
    statements,
    Ok(TypeOut(environment, NilType)),
    fn(state, stmnt) {
      case state {
        Error(_) -> list.Stop(state)
        Ok(type_out) -> list.Continue(statement(type_out.environment, stmnt))
      }
    },
  )
}

pub fn statement(
  environment: Environment,
  statement: glance.Statement,
) -> TypeCheckResult {
  case statement {
    glance.Expression(expr) -> expression(environment, expr)
    _ -> todo
  }
}

pub fn expression(
  environment: Environment,
  expression: glance.Expression,
) -> TypeCheckResult {
  case expression {
    // TODO: Not 100% sure this will ever need to update the environment,
    // so we may be able to remove it from the return
    glance.Int(_) -> Ok(TypeOut(environment, IntType))
    glance.Float(_) -> Ok(TypeOut(environment, FloatType))
    glance.String(_) -> Ok(TypeOut(environment, StringType))
    glance.Variable("Nil") -> Ok(TypeOut(environment, NilType))
    glance.Variable(name) -> lookup_type_out(environment, name)
    _ -> {
      pprint.debug(expression)
      todo
    }
  }
}

pub fn type_(
  environment: Environment,
  glance_type: glance.Type,
) -> Result(Type, error.TypeCheckError) {
  case glance_type {
    glance.NamedType("Int", option.None, []) -> Ok(IntType)
    glance.NamedType("Float", option.None, []) -> Ok(FloatType)
    glance.NamedType("Nil", option.None, []) -> Ok(NilType)
    glance.NamedType("String", option.None, []) -> Ok(StringType)
    glance.VariableType(name) -> lookup_type(environment, name)
    _ -> {
      pprint.debug(glance_type)
      todo
    }
  }
}

fn add_def(environment: Environment, name: String, type_: Type) -> Environment {
  Environment(
    // ..environment,
    definitions: dict.insert(environment.definitions, name, type_),
  )
}

fn lookup_type(
  environment: Environment,
  name: String,
) -> Result(Type, error.TypeCheckError) {
  dict.get(environment.definitions, name)
  |> result.replace_error(error.InvalidName(name))
}

fn lookup_type_out(
  environment: Environment,
  name: String,
) -> Result(TypeOut, error.TypeCheckError) {
  dict.get(environment.definitions, name)
  |> result.replace_error(error.InvalidName(name))
  |> result.map(TypeOut(environment, _))
}
