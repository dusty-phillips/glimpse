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
) -> Result(#(glimpse.Package, Environment), error.TypeCheckError) {
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
) -> Result(Environment, error.TypeCheckError) {
  case environment.custom_types |> dict.get(custom_type.name) {
    Ok(_) -> Error(error.DuplicateCustomType(custom_type.name))
    Error(_) -> {
      // add to env first so variants can parse recursive types
      let environment =
        environment |> environment.add_custom_type(custom_type.name)

      list.fold_until(
        custom_type.variants,
        Ok(environment.TypeState(
          environment,
          types.CustomType(custom_type.name),
        )),
        intern.fold_variant_constructors,
      )
      |> result.map(environment.extract_env)
    }
  }
  // Problem: where do we put the variant?
  //
  // probably a new constructors dict on the environment class
  // that maps constructor name to CustomType(name)
  // but it could also be in the definitions.
  // We can't put both the type and the variant in the definitions, though
  // because variants could lobber the type.
  //
  // Problem: do we need to do anything special with single variant custom
  // types? If there is only one variant, we are allowed to look up record fields
  // on the type.
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
