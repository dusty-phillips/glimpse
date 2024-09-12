import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import glimpse
import glimpse/error
import glimpse/internal/typecheck as intern
import glimpse/internal/typecheck/environment.{type Environment}
import glimpse/internal/typecheck/types

/// Infer and typecheck a single module in the given package. Any modules that
/// this module imports *must* have already been inferred.
///
/// Returns a variation of the package where the module's contents have been
/// updated based on any inferences that were made.
pub fn module(
  package: glimpse.Package,
  module_name: String,
) -> Result(glimpse.Package, error.TypeCheckError) {
  let glimpse_module_result =
    dict.get(package.modules, module_name)
    |> result.replace_error(error.NoSuchModule(module_name))

  use glimpse_module <- result.try(glimpse_module_result)

  let environment = environment.new()
  // TODO: Put custom types, imports, consts in the env

  // I'm pretty sure functions cannot update the global environment,
  // so we don't need to reassign it.
  let functions_result =
    glimpse_module.module.functions
    |> list.map(fn(definition) {
      use updated_function <- result.try(function(
        environment,
        definition.definition,
      ))
      Ok(glance.Definition(..definition, definition: updated_function))
    })
    |> result.all()

  use functions <- result.try(functions_result)

  let glance_module =
    glance.Module(..glimpse_module.module, functions: functions)
  let glimpse_module = glimpse.Module(..glimpse_module, module: glance_module)
  let module_dict = dict.insert(package.modules, module_name, glimpse_module)
  let package = glimpse.Package(..package, modules: module_dict)
  Ok(package)
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
