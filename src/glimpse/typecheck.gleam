import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import glimpse
import glimpse/error
import glimpse/internal/typecheck as intern
import glimpse/internal/typecheck/environment.{
  type Environment, type EnvironmentFold, type EnvironmentResult,
}
import glimpse/internal/typecheck/functions
import glimpse/internal/typecheck/types

/// Infer and typecheck a single module in the given package. Any modules that
/// this module imports *must* have already been inferred.
///
/// Returns a variation of the package where the module's contents have been
/// updated based on any inferences that were made.
pub fn module(
  package: glimpse.Package,
  module_name: String,
) -> error.TypeCheckResult(#(glimpse.Package, Environment)) {
  let glimpse_module_result =
    dict.get(package.modules, module_name)
    |> result.replace_error(error.NoSuchModule(module_name))

  use glimpse_module <- result.try(glimpse_module_result)

  let environment = environment.new()

  let custom_type_result =
    glimpse_module.module.custom_types
    |> list.fold_until(Ok(environment), fn(state, glance_custom_type) {
      case state {
        Error(error) -> list.Stop(Error(error))
        Ok(environment) ->
          list.Continue(custom_type(environment, glance_custom_type.definition))
      }
    })

  use environment <- result.try(custom_type_result)

  let function_signature_result =
    glimpse_module.module.functions
    |> list.map(fn(definition) { definition.definition })
    |> list.fold_until(Ok(environment), function_signature)

  use environment <- result.try(function_signature_result)

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
  Ok(#(package, environment))
  // TODO: Pretty sure this needs to also return an updated environment
  // that contains the public types and functions of the module
}

/// Update the environment to include the custom type and all its constructors.
pub fn custom_type(
  environment: Environment,
  custom_type: glance.CustomType,
) -> EnvironmentResult {
  case environment.custom_types |> dict.get(custom_type.name) {
    Ok(_) -> Error(error.DuplicateCustomType(custom_type.name))
    Error(_) -> {
      // add to env first so variants can parse recursive types
      let environment =
        environment |> environment.add_custom_type(custom_type.name)

      list.fold_until(
        custom_type.variants,
        Ok(environment.EnvState(environment, types.CustomType(custom_type.name))),
        intern.fold_variant_constructors_into_env,
      )
      |> result.map(environment.extract_env)
    }
  }
  // TODO: Also add variants
}

/// Given a glance function signature, inject that signature into the environment definitions as
/// a callable type. The body is not typechecked at this point.
/// TODO: Inferring function parameter types
pub fn function_signature(
  state: EnvironmentResult,
  function: glance.Function,
) -> EnvironmentFold {
  case state {
    Error(error) -> list.Stop(Error(error))
    Ok(environment) ->
      {
        use param_state <- result.try(
          function.parameters
          |> list.fold_until(
            Ok(functions.empty_state(environment)),
            intern.fold_parameter_into_callable,
          ),
        )

        case function.return {
          option.None -> todo as "not inferring return values yet"
          option.Some(glance_return_type) -> {
            use return <- result.try(environment.type_(
              environment,
              glance_return_type,
            ))
            Ok(
              environment
              |> environment.add_def(
                function.name,
                functions.to_callable_type(param_state, return),
              ),
            )
          }
        }
      }
      |> list.Continue
  }
}

/// Takes a glance function as input and returns the same function, but
/// with the inferred return type if the original function did not have
/// a return type. Returns an error if anything in the function doesn't
/// typecheck.
pub fn function(
  environment: Environment,
  function: glance.Function,
) -> error.TypeCheckResult(glance.Function) {
  use environment <- result.try(list.fold_until(
    function.parameters,
    Ok(environment),
    intern.fold_function_parameter_into_env,
  ))

  case intern.block(environment, function.body) {
    Error(err) -> Error(err)
    Ok(block_out) ->
      case function.return {
        option.None -> {
          Ok(
            glance.Function(
              ..function,
              return: option.Some(types.to_glance(block_out.state)),
            ),
          )
        }
        option.Some(expected_type) -> {
          case environment.type_(environment, expected_type) {
            Error(err) -> Error(err)
            Ok(expected) if expected != block_out.state ->
              Error(error.InvalidReturnType(
                function.name,
                block_out.state |> types.to_string,
                expected |> types.to_string,
              ))
            Ok(_) -> Ok(function)
          }
        }
      }
  }
}
