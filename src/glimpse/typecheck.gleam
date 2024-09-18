import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import glimpse
import glimpse/error
import glimpse/internal/import_dependencies
import glimpse/internal/typecheck as intern
import glimpse/internal/typecheck/environment.{
  type Environment, type EnvironmentResult,
}
import glimpse/internal/typecheck/functions
import glimpse/internal/typecheck/imports
import glimpse/internal/typecheck/types

type PackageState {
  PackageState(
    package: glimpse.Package,
    module_envs: dict.Dict(String, Environment),
  )
}

/// Infer and typecheck a glimpse package. Returns a new version of the package,
/// where some glance types may have been replaced with inferred types.
///
/// Checks the main module and every module that is importable from that module.
///
/// Returns a GlimpseError if there are missing imports, circular dependencies,
/// or anything in the AST fails to typecheck.
pub fn package(
  package: glimpse.Package,
) -> Result(glimpse.Package, error.GlimpseError(a)) {
  let import_graph =
    dict.map_values(package.modules, fn(_, value) { value.dependencies })

  use ordered_dependencies <- result.try(import_dependencies.sort_dependencies(
    import_graph,
    package.name,
  ))
  ordered_dependencies
  |> list.fold_until(
    Ok(PackageState(package, dict.new())),
    fn(package_result, next_module) {
      case package_result {
        Error(error) -> list.Stop(Error(error))
        Ok(PackageState(package, module_envs)) ->
          {
            use glimpse_module <- result.try(
              dict.get(package.modules, next_module)
              |> result.replace_error(
                error.ImportError(error.MissingImportError(next_module)),
              ),
            )
            use #(new_module, module_env) <- result.try(
              module(glimpse_module, module_envs)
              |> result.map_error(error.TypeCheckError),
            )

            let module_dict =
              dict.insert(package.modules, next_module, new_module)
            let new_package = glimpse.Package(..package, modules: module_dict)
            Ok(PackageState(
              new_package,
              dict.insert(module_envs, next_module, module_env),
            ))
          }
          |> list.Continue
      }
    },
  )
  |> result.map(fn(state) { state.package })
}

/// Infer and typecheck a single module in the given package. Any modules that
/// this module imports *must* have already been inferred.
///
/// Returns a variation of the package where the module's contents have been
/// updated based on any inferences that were made.
pub fn module(
  glimpse_module: glimpse.Module,
  module_envs: dict.Dict(String, Environment),
) -> error.TypeCheckResult(#(glimpse.Module, Environment)) {
  let environment = environment.new(glimpse_module.name)

  let imports_result =
    glimpse_module.module.imports
    |> list.map(fn(definition) { definition.definition })
    |> list.fold_until(
      Ok(environment.EnvState(environment, module_envs)),
      imports.fold_import_from_env,
    )

  use environment.EnvState(environment, _) <- result.try(imports_result)

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
    |> list.fold_until(Ok(environment), functions.function_signature)

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

  let new_glance_module =
    glance.Module(..glimpse_module.module, functions: functions)
  let new_glimpse_module =
    glimpse.Module(..glimpse_module, module: new_glance_module)
  Ok(#(new_glimpse_module, environment))
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
        Ok(environment.EnvState(environment, custom_type)),
        functions.fold_variant_constructors_into_env,
      )
      |> result.map(environment.extract_env)
    }
  }
  // TODO: Also add variants
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
    functions.fold_function_parameter_into_env,
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
