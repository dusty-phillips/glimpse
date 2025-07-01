import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import glimpse/error
import glimpse/internal/typecheck/functions
import glimpse/internal/typecheck/types.{
  type Environment, type Type, type TypeResult, type TypeStateResult,
}

pub fn block(
  environment: Environment,
  statements: List(glance.Statement),
) -> TypeStateResult {
  list.fold_until(
    statements,
    Ok(types.EnvState(environment, types.NilType)),
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
      |> result.map(types.EnvState(environment, _))

    glance.Assignment(
      _,
      glance.Let,
      glance.PatternVariable(_, name),
      annotation,
      value_expression,
    ) -> {
      let value_type_result = expression(environment, value_expression)
      let annotated_type_option =
        option.map(annotation, types.type_(environment, _))

      let inferred_type_result = case value_type_result, annotated_type_option {
        Error(err), _ -> Error(err)
        _, option.Some(Error(err)) -> Error(err)
        Ok(value_type), option.None -> Ok(value_type)
        Ok(value_type), option.Some(Ok(annotated_type))
          if value_type == annotated_type
        -> Ok(value_type)
        Ok(value_type), option.Some(Ok(annotated_type)) ->
          Error(error.InvalidType(
            types.to_string(environment, value_type),
            types.to_string(environment, annotated_type),
            "during assignment of " <> name,
          ))
      }

      use type_ <- result.try(inferred_type_result)
      let updated_environment =
        types.add_or_update_def_in_env(environment, name, type_)
      Ok(types.EnvState(updated_environment, type_))
    }
    _ -> {
      echo statement
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
    glance.Int(_, _) -> Ok(types.IntType)
    glance.Float(_, _) -> Ok(types.FloatType)
    glance.String(_, _) -> Ok(types.StringType)
    glance.Variable(_, "Nil") -> Ok(types.NilType)
    glance.Variable(_, "True") | glance.Variable(_, "False") ->
      Ok(types.BoolType)
    glance.Variable(_, name) -> types.lookup_variable_type(environment, name)

    glance.NegateInt(_, int_expr) -> {
      case expression(environment, int_expr) {
        Error(err) -> Error(err)
        Ok(types.IntType) -> Ok(types.IntType)
        Ok(got) ->
          Error(error.InvalidType(
            types.to_string(environment, got),
            "Int",
            "- can only negate Int",
          ))
      }
    }

    glance.NegateBool(_, int_expr) -> {
      case expression(environment, int_expr) {
        Error(err) -> Error(err)
        Ok(types.BoolType) -> Ok(types.BoolType)
        Ok(got) ->
          Error(error.InvalidType(
            types.to_string(environment, got),
            "Bool",
            "! can only negate Bool",
          ))
      }
    }

    glance.FieldAccess(_, container, label) -> {
      use container_expression_type <- result.try(expression(
        environment,
        container,
      ))
      case container_expression_type {
        types.NamespaceType(nested_defs, _nested_types) ->
          nested_defs
          |> dict.get(label)
          |> result.replace_error(error.InvalidName(label))
        type_ ->
          Error(error.InvalidFieldAccess(
            types.to_string(environment, type_),
            label,
          ))
      }
    }

    glance.Call(_, target, arguments) -> call(environment, target, arguments)

    glance.BinaryOperator(_, operator, left, right) ->
      binop(environment, operator, left, right)

    _ -> {
      echo expr
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
        environment,
        glimpse_argument_fields,
        target_arguments,
        target_labels,
      )
      |> result.replace(target_return)
    }
    types.GenericCallableType(
      _target_arguments,
      target_labels,
      _target_return,
      original_function,
    ) -> {
      let concrete_arg_types =
        list.map(glimpse_argument_fields, fn(field) {
          case field {
            glance.LabelledField(_, type_) -> type_
            glance.UnlabelledField(type_) -> type_
            glance.ShorthandField(_) ->
              panic as "ShorthandField should have been converted by call_field"
          }
        })

      typecheck_function_with_concrete_types(
        environment,
        original_function,
        concrete_arg_types,
      )
    }
    _ -> Error(error.NotCallable(types.to_string(environment, glimpse_target)))
  }
}

pub fn call_field(
  environment: Environment,
  field: glance.Field(glance.Expression),
) -> error.TypeCheckResult(glance.Field(types.Type)) {
  case field {
    glance.LabelledField(label, arg_expr) ->
      expression(environment, arg_expr)
      |> result.map(glance.LabelledField(label, _))
    glance.UnlabelledField(arg_expr) ->
      expression(environment, arg_expr)
      |> result.map(glance.UnlabelledField)
    glance.ShorthandField(label) ->
      types.lookup_variable_type(environment, label)
      |> result.map(glance.LabelledField(label, _))
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
      types.to_binop_error(environment, "&&", left, right, "two Bools")
    glance.Or, left, right ->
      types.to_binop_error(environment, "||", left, right, "two Bools")

    glance.Eq, left, right ->
      types.to_binop_error(environment, "==", left, right, "same type")
    glance.NotEq, left, right ->
      types.to_binop_error(environment, "!=", left, right, "same type")

    glance.LtInt, left, right ->
      types.to_binop_error(environment, "<", left, right, "two Ints")
    glance.LtFloat, left, right ->
      types.to_binop_error(environment, "<.", left, right, "two Floats")
    glance.LtEqInt, left, right ->
      types.to_binop_error(environment, "<=", left, right, "two Ints")
    glance.LtEqFloat, left, right ->
      types.to_binop_error(environment, "<=.", left, right, "two Floats")
    glance.GtInt, left, right ->
      types.to_binop_error(environment, ">", left, right, "two Ints")
    glance.GtFloat, left, right ->
      types.to_binop_error(environment, ">.", left, right, "two Floats")
    glance.GtEqInt, left, right ->
      types.to_binop_error(environment, ">=", left, right, "two Ints")
    glance.GtEqFloat, left, right ->
      types.to_binop_error(environment, ">=.", left, right, "two Floats")
    glance.AddInt, left, right ->
      types.to_binop_error(environment, "+", left, right, "two Ints")
    glance.AddFloat, left, right ->
      types.to_binop_error(environment, "+.", left, right, "two Floats")
    glance.SubInt, left, right ->
      types.to_binop_error(environment, "-", left, right, "two Ints")
    glance.SubFloat, left, right ->
      types.to_binop_error(environment, "-.", left, right, "two Floats")
    glance.MultInt, left, right ->
      types.to_binop_error(environment, "*", left, right, "two Ints")
    glance.MultFloat, left, right ->
      types.to_binop_error(environment, "*.", left, right, "two Floats")
    glance.DivInt, left, right ->
      types.to_binop_error(environment, "/", left, right, "two Ints")
    glance.DivFloat, left, right ->
      types.to_binop_error(environment, "/.", left, right, "two Floats")
    glance.RemainderInt, left, right ->
      types.to_binop_error(environment, "%", left, right, "two Ints")

    glance.Concatenate, left, right ->
      types.to_binop_error(environment, "<>", left, right, "two Strings")

    glance.Pipe, _, _ -> todo as "Pipe binop is not typechecked yet"
  }
}

fn typecheck_function_with_concrete_types(
  environment: Environment,
  original_function: glance.Function,
  concrete_arg_types: List(Type),
) -> error.TypeCheckResult(Type) {
  let param_count = list.length(original_function.parameters)
  let arg_count = list.length(concrete_arg_types)

  case param_count == arg_count {
    False -> {
      let param_types =
        list.map(original_function.parameters, fn(param) {
          case param {
            glance.FunctionParameter(type_: option.Some(glance_type), ..) ->
              case types.type_(environment, glance_type) {
                Ok(type_) -> types.to_string(environment, type_)
                Error(_) -> "unknown"
              }
            _ -> "unknown"
          }
        })
      let arg_type_strings =
        list.map(concrete_arg_types, types.to_string(environment, _))

      Error(error.InvalidArguments(
        "(" <> string.join(param_types, ", ") <> ")",
        "(" <> string.join(arg_type_strings, ", ") <> ")",
      ))
    }
    True -> {
      use param_env <- result.try(
        list.zip(original_function.parameters, concrete_arg_types)
        |> list.fold(Ok(environment), fn(env_result, param_type) {
          use env <- result.try(env_result)
          let #(param, concrete_type) = param_type
          case param {
            glance.FunctionParameter(name: glance.Named(name), ..) ->
              Ok(types.add_or_update_def_in_env(env, name, concrete_type))
            _ -> Ok(env)
          }
        }),
      )

      use body_result <- result.try(block(param_env, original_function.body))
      Ok(body_result.state)
    }
  }
}
