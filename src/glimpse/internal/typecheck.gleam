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
  pprint.debug(expression)
  case expression {
    // TODO: Not 100% sure this will ever need to update the environment,
    // so we may be able to remove it from the return
    glance.Int(_) -> Ok(environment.TypeOut(environment, types.IntType))
    glance.Float(_) -> Ok(environment.TypeOut(environment, types.FloatType))
    glance.String(_) -> Ok(environment.TypeOut(environment, types.StringType))
    glance.Variable("Nil") ->
      Ok(environment.TypeOut(environment, types.NilType))
    glance.Variable("True") | glance.Variable("False") ->
      Ok(environment.TypeOut(environment, types.BoolType))
    glance.Variable(name) -> environment.lookup_type_out(environment, name)
    glance.BinaryOperator(operator, left, right) ->
      binop(environment, operator, left, right)

    _ -> {
      pprint.debug(expression)
      todo
    }
  }
}

pub fn binop(
  environment: Environment,
  operator: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
) -> TypeCheckResult {
  use environment.TypeOut(environment, left_type) <- result.try(expression(
    environment,
    left,
  ))
  use environment.TypeOut(environment, right_type) <- result.try(expression(
    environment,
    right,
  ))
  case operator, left_type, right_type {
    glance.LtInt, types.IntType, types.IntType
    | glance.LtEqInt, types.IntType, types.IntType
    | glance.GtInt, types.IntType, types.IntType
    | glance.GtEqInt, types.IntType, types.IntType
    | glance.AddInt, types.IntType, types.IntType
    | glance.SubInt, types.IntType, types.IntType
    | glance.MultInt, types.IntType, types.IntType
    | glance.DivInt, types.IntType, types.IntType
    | glance.RemainderInt, types.IntType, types.IntType
    -> Ok(environment.TypeOut(environment, types.IntType))

    glance.LtFloat, types.FloatType, types.FloatType
    | glance.LtEqFloat, types.FloatType, types.FloatType
    | glance.GtFloat, types.FloatType, types.FloatType
    | glance.GtEqFloat, types.FloatType, types.FloatType
    | glance.AddFloat, types.FloatType, types.FloatType
    | glance.SubFloat, types.FloatType, types.FloatType
    | glance.MultFloat, types.FloatType, types.FloatType
    | glance.DivFloat, types.FloatType, types.FloatType
    -> Ok(environment.TypeOut(environment, types.FloatType))

    glance.Concatenate, types.StringType, types.StringType ->
      Ok(environment.TypeOut(environment, types.StringType))

    glance.LtInt, left, right ->
      environment.to_binop_error("<", left, right, "two Ints")
    glance.LtFloat, left, right ->
      environment.to_binop_error("<.", left, right, "two Floats")
    glance.LtEqInt, left, right ->
      environment.to_binop_error("<=", left, right, "two Ints")
    glance.LtEqFloat, left, right ->
      environment.to_binop_error("<=.", left, right, "two Floats")
    glance.GtInt, left, right ->
      environment.to_binop_error(">", left, right, "two Ints")
    glance.GtFloat, left, right ->
      environment.to_binop_error(">.", left, right, "two Floats")
    glance.GtEqInt, left, right ->
      environment.to_binop_error(">=", left, right, "two Ints")
    glance.GtEqFloat, left, right ->
      environment.to_binop_error(">=.", left, right, "two Floats")
    glance.AddInt, left, right ->
      environment.to_binop_error("+", left, right, "two Ints")
    glance.AddFloat, left, right ->
      environment.to_binop_error("+.", left, right, "two Floats")
    glance.SubInt, left, right ->
      environment.to_binop_error("-", left, right, "two Ints")
    glance.SubFloat, left, right ->
      environment.to_binop_error("-.", left, right, "two Floats")
    glance.MultInt, left, right ->
      environment.to_binop_error("*", left, right, "two Ints")
    glance.MultFloat, left, right ->
      environment.to_binop_error("*.", left, right, "two Floats")
    glance.DivInt, left, right ->
      environment.to_binop_error("/", left, right, "two Ints")
    glance.DivFloat, left, right ->
      environment.to_binop_error("/.", left, right, "two Floats")
    glance.RemainderInt, left, right ->
      environment.to_binop_error("%", left, right, "two Ints")
    glance.Concatenate, left, right ->
      environment.to_binop_error("<>", left, right, "two Strings")

    _, _, _ -> todo as "Most binops not typechecked yet"
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
    glance.NamedType("Bool", option.None, []) -> Ok(types.BoolType)
    glance.VariableType(name) -> environment.lookup_type(environment, name)
    _ -> {
      pprint.debug(glance_type)
      todo
    }
  }
}
