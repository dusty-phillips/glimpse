import glance
import gleam/list
import gleam/option
import gleam/result
import glimpse/error
import glimpse/internal/typecheck/environment.{
  type Environment, type TypeStateResult,
}
import glimpse/internal/typecheck/functions
import glimpse/internal/typecheck/types.{type TypeResult}
import pprint

pub fn block(
  environment: Environment,
  statements: List(glance.Statement),
) -> TypeStateResult {
  list.fold_until(
    statements,
    Ok(environment.EnvState(environment, types.NilType)),
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
) -> TypeStateResult {
  case statement {
    glance.Expression(expr) ->
      expression(environment, expr)
      |> result.map(environment.EnvState(environment, _))

    glance.Assignment(
      glance.Let,
      glance.PatternVariable(name),
      annotation,
      value_expression,
    ) -> {
      let value_type_result = expression(environment, value_expression)
      let annotated_type_option =
        option.map(annotation, environment.type_(environment, _))

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
      Ok(environment.EnvState(updated_environment, type_))
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
    glance.Variable(name) -> environment.lookup_variable_type(environment, name)

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

    glance.Call(target, arguments) -> call(environment, target, arguments)

    glance.BinaryOperator(operator, left, right) ->
      binop(environment, operator, left, right)

    _ -> {
      pprint.debug(expr)
      todo as "many expressions not implemented yet"
    }
  }
}

pub fn call(
  environment: Environment,
  target: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
) -> TypeResult {
  let glimpse_argument_fields_result =
    arguments
    |> list.map(call_field(environment, _))
    |> result.all

  use glimpse_target <- result.try(expression(environment, target))
  use glimpse_argument_fields <- result.try(glimpse_argument_fields_result)

  case glimpse_target {
    types.CallableType(target_arguments, target_labels, target_return) -> {
      functions.order_call_arguments(
        glimpse_argument_fields,
        target_arguments,
        target_labels,
      )
      |> result.replace(target_return)
    }
    _ -> Error(error.NotCallable(types.to_string(glimpse_target)))
  }
}

pub fn call_field(
  environment: Environment,
  field: glance.Field(glance.Expression),
) -> error.TypeCheckResult(glance.Field(types.Type)) {
  case field {
    glance.Field(label_opt, arg_expr) -> {
      use type_ <- result.try(expression(environment, arg_expr))
      Ok(glance.Field(label_opt, type_))
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
