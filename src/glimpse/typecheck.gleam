import glance
import gleam/list
import gleam/option
import gleam/result
import glimpse
import glimpse/error
import glimpse/internal/typecheck as intern
import glimpse/internal/typecheck/environment.{
  type Environment, type TypeCheckResult,
}
import glimpse/internal/typecheck/types

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
    intern.fold_function_parameter,
  ))

  case intern.block(environment, function.body) {
    Error(err) -> Error(err)
    Ok(block_out) ->
      case function.return {
        option.None -> {
          Ok(
            glance.Function(
              ..function,
              return: option.Some(types.to_glance(block_out.type_)),
            ),
          )
        }
        option.Some(expected_type) -> {
          case intern.type_(environment, expected_type) {
            Error(err) -> Error(err)
            Ok(expected) if expected != block_out.type_ ->
              Error(error.InvalidReturnType(
                function.name,
                block_out.type_ |> types.to_string,
                expected |> types.to_string,
              ))
            Ok(_) -> Ok(function)
          }
        }
      }
  }
}
