import glance
import gleam/list
import gleam/option
import gleam/result
import glimpse/error
import glimpse/internal/typecheck/environment.{
  type Environment, type TypeCheckResult,
}
import glimpse/internal/typecheck/types.{type Type}
import pprint

pub fn fold_function_parameter(
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
            Ok(environment.add_def(environment, name, check_type))
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
    Ok(environment.TypeOut(environment, types.NilType)),
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
    glance.Int(_) -> Ok(environment.TypeOut(environment, types.IntType))
    glance.Float(_) -> Ok(environment.TypeOut(environment, types.FloatType))
    glance.String(_) -> Ok(environment.TypeOut(environment, types.StringType))
    glance.Variable("Nil") ->
      Ok(environment.TypeOut(environment, types.NilType))
    glance.Variable(name) -> environment.lookup_type_out(environment, name)
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
    glance.NamedType("Int", option.None, []) -> Ok(types.IntType)
    glance.NamedType("Float", option.None, []) -> Ok(types.FloatType)
    glance.NamedType("Nil", option.None, []) -> Ok(types.NilType)
    glance.NamedType("String", option.None, []) -> Ok(types.StringType)
    glance.VariableType(name) -> environment.lookup_type(environment, name)
    _ -> {
      pprint.debug(glance_type)
      todo
    }
  }
}
