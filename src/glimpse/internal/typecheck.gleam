import glance
import gleam/list
import gleam/option
import gleam/result
import glimpse/error
import glimpse/internal/typecheck/environment.{
  type Environment, type TypeCheckResult,
}
import glimpse/internal/typecheck/types.{type TypeResult}
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
    Ok(environment.TypeState(environment, types.NilType)),
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
    glance.Expression(expr) ->
      expression(environment, expr)
      |> result.map(environment.TypeState(environment, _))

    glance.Assignment(
      glance.Let,
      glance.PatternVariable(name),
      annotation,
      value_expression,
    ) -> {
      let value_type_result = expression(environment, value_expression)
      let annotated_type_option = option.map(annotation, type_(environment, _))

      let inferred_type_result = case value_type_result, annotated_type_option {
        Error(err), _ -> Error(err)
        _, option.Some(Error(err)) -> Error(err)
        Ok(value_type), option.None -> Ok(value_type)
        Ok(value_type), option.Some(Ok(annotated_type))
          if value_type == annotated_type
        -> Ok(value_type)
        Ok(value_type), option.Some(Ok(annotated_type)) ->
          Error(error.InvalidType(
            value_type |> types.to_string,
            annotated_type |> types.to_string,
            "during assignment of " <> name,
          ))
      }

      use type_ <- result.try(inferred_type_result)
      let updated_environment = environment.add_def(environment, name, type_)
      Ok(environment.TypeState(updated_environment, type_))
    }
    _ -> {
      pprint.debug(statement)
      todo as "most statement types not covered yet"
    }
  }
}

pub fn expression(
  environment: Environment,
  expr: glance.Expression,
) -> TypeResult {
  case expr {
    // TODO: Not 100% sure this will ever need to update the environment,
    // so we may be able to remove it from the return
    glance.Int(_) -> Ok(types.IntType)
    glance.Float(_) -> Ok(types.FloatType)
    glance.String(_) -> Ok(types.StringType)
    glance.Variable("Nil") -> Ok(types.NilType)
    glance.Variable("True") | glance.Variable("False") -> Ok(types.BoolType)
    glance.Variable(name) -> environment.lookup_type(environment, name)

    glance.NegateInt(int_expr) -> {
      case expression(environment, int_expr) {
        Error(err) -> Error(err)
        Ok(types.IntType) -> Ok(types.IntType)
        Ok(got) ->
          Error(error.InvalidType(
            got |> types.to_string,
            "Int",
            "- can only negate Int",
          ))
      }
    }

    glance.NegateBool(int_expr) -> {
      case expression(environment, int_expr) {
        Error(err) -> Error(err)
        Ok(types.BoolType) -> Ok(types.BoolType)
        Ok(got) ->
          Error(error.InvalidType(
            got |> types.to_string,
            "Bool",
            "! can only negate Bool",
          ))
      }
    }

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
) -> TypeResult {
  // TODO: I have a feeling precedence matters here. ;-)
  use left_type <- result.try(expression(environment, left))
  use right_type <- result.try(expression(environment, right))

  case operator, left_type, right_type {
    glance.And, types.BoolType, types.BoolType
    | glance.Or, types.BoolType, types.BoolType
    -> Ok(types.BoolType)

    glance.Eq, left_type, right_type | glance.NotEq, left_type, right_type
      if left_type == right_type
    -> Ok(left_type)

    glance.LtInt, types.IntType, types.IntType
    | glance.LtEqInt, types.IntType, types.IntType
    | glance.GtInt, types.IntType, types.IntType
    | glance.GtEqInt, types.IntType, types.IntType
    | glance.AddInt, types.IntType, types.IntType
    | glance.SubInt, types.IntType, types.IntType
    | glance.MultInt, types.IntType, types.IntType
    | glance.DivInt, types.IntType, types.IntType
    | glance.RemainderInt, types.IntType, types.IntType
    -> Ok(types.IntType)

    glance.LtFloat, types.FloatType, types.FloatType
    | glance.LtEqFloat, types.FloatType, types.FloatType
    | glance.GtFloat, types.FloatType, types.FloatType
    | glance.GtEqFloat, types.FloatType, types.FloatType
    | glance.AddFloat, types.FloatType, types.FloatType
    | glance.SubFloat, types.FloatType, types.FloatType
    | glance.MultFloat, types.FloatType, types.FloatType
    | glance.DivFloat, types.FloatType, types.FloatType
    -> Ok(types.FloatType)

    glance.Concatenate, types.StringType, types.StringType ->
      Ok(types.StringType)

    glance.And, left, right ->
      types.to_binop_error("&&", left, right, "two Bools")
    glance.Or, left, right ->
      types.to_binop_error("||", left, right, "two Bools")

    glance.Eq, left, right ->
      types.to_binop_error("==", left, right, "same type")
    glance.NotEq, left, right ->
      types.to_binop_error("!=", left, right, "same type")

    glance.LtInt, left, right ->
      types.to_binop_error("<", left, right, "two Ints")
    glance.LtFloat, left, right ->
      types.to_binop_error("<.", left, right, "two Floats")
    glance.LtEqInt, left, right ->
      types.to_binop_error("<=", left, right, "two Ints")
    glance.LtEqFloat, left, right ->
      types.to_binop_error("<=.", left, right, "two Floats")
    glance.GtInt, left, right ->
      types.to_binop_error(">", left, right, "two Ints")
    glance.GtFloat, left, right ->
      types.to_binop_error(">.", left, right, "two Floats")
    glance.GtEqInt, left, right ->
      types.to_binop_error(">=", left, right, "two Ints")
    glance.GtEqFloat, left, right ->
      types.to_binop_error(">=.", left, right, "two Floats")
    glance.AddInt, left, right ->
      types.to_binop_error("+", left, right, "two Ints")
    glance.AddFloat, left, right ->
      types.to_binop_error("+.", left, right, "two Floats")
    glance.SubInt, left, right ->
      types.to_binop_error("-", left, right, "two Ints")
    glance.SubFloat, left, right ->
      types.to_binop_error("-.", left, right, "two Floats")
    glance.MultInt, left, right ->
      types.to_binop_error("*", left, right, "two Ints")
    glance.MultFloat, left, right ->
      types.to_binop_error("*.", left, right, "two Floats")
    glance.DivInt, left, right ->
      types.to_binop_error("/", left, right, "two Ints")
    glance.DivFloat, left, right ->
      types.to_binop_error("/.", left, right, "two Floats")
    glance.RemainderInt, left, right ->
      types.to_binop_error("%", left, right, "two Ints")

    glance.Concatenate, left, right ->
      types.to_binop_error("<>", left, right, "two Strings")

    glance.Pipe, _, _ -> todo as "Pipe binop is not typechecked yet"
  }
}

pub fn type_(environment: Environment, glance_type: glance.Type) -> TypeResult {
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
