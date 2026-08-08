import glance
import gleam/result
import glimpse/error
import glimpse/internal/typecheck/calls
import glimpse/internal/typecheck/types.{
  type Environment, type Type, type TypeStore,
}

/// Unify both operands against the expected operand type, returning `Bool`
/// (the result of a comparison operator) if they both match.
pub fn check_comparison_operands(
  environment: Environment,
  store: TypeStore,
  operator: String,
  left: Type,
  right: Type,
  expected: String,
  expected_type: Type,
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  check_operands(
    environment,
    store,
    operator,
    left,
    right,
    expected,
    expected_type,
  )
  |> result.map(fn(state) {
    let #(store, _) = state
    #(store, types.BoolType)
  })
}

/// Unify both operands against the expected operand type, returning that type
/// if they both match. Errors use the original operand types in the message.
pub fn check_operands(
  environment: Environment,
  store: TypeStore,
  operator: String,
  left: Type,
  right: Type,
  expected: String,
  expected_type: Type,
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  types.unify(store, environment, left, expected_type)
  |> result.try(fn(store) {
    types.unify(store, environment, right, expected_type)
  })
  |> result.map(fn(store) { #(store, expected_type) })
  |> result.map_error(fn(_) {
    let #(store, resolved_left) = types.resolve(store, left)
    let #(_store, resolved_right) = types.resolve(store, right)
    error.InvalidBinOp(
      operator,
      types.to_string(environment, resolved_left),
      types.to_string(environment, resolved_right),
      expected,
    )
  })
}

pub fn operator_string(operator: glance.BinaryOperator) -> String {
  case operator {
    glance.And -> "&&"
    glance.Or -> "||"
    glance.Eq -> "=="
    glance.NotEq -> "!="
    glance.LtInt -> "<"
    glance.LtEqInt -> "<="
    glance.GtEqInt -> ">="
    glance.GtInt -> ">"
    glance.LtFloat -> "<."
    glance.LtEqFloat -> "<=."
    glance.GtEqFloat -> ">=."
    glance.GtFloat -> ">."
    glance.AddInt -> "+"
    glance.AddFloat -> "+."
    glance.SubInt -> "-"
    glance.SubFloat -> "-."
    glance.MultInt -> "*"
    glance.MultFloat -> "*."
    glance.DivInt -> "/"
    glance.DivFloat -> "/."
    glance.RemainderInt -> "%"
    glance.Concatenate -> "<>"
    glance.Pipe -> "|>"
  }
}

/// The call's arguments already fill every parameter, so the piped value is
/// applied to the value the call returns, which must itself be a function.
pub fn pipe_value_into_result(
  environment: Environment,
  store: TypeStore,
  left_type: Type,
  return: Type,
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  use #(store, parameters, _labels, result_return) <- result.try(
    calls.callable_parts(environment, store, return, 1)
    |> result.map_error(fn(_) { error.InvalidArguments("()", "a piped value") }),
  )
  case parameters {
    [] -> Error(error.InvalidArguments("()", "a piped value"))
    [first_param, ..] -> {
      use store <- result.try(types.unify(
        store,
        environment,
        left_type,
        first_param,
      ))
      Ok(types.resolve(store, result_return))
    }
  }
}
