import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import glimpse
import glimpse/error
import glimpse/internal/import_dependencies
import glimpse/internal/typecheck as intern
import glimpse/internal/typecheck/functions
import glimpse/internal/typecheck/imports
import glimpse/internal/typecheck/types.{
  type Environment, type EnvironmentResult,
}

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
  let environment = types.new_env(glimpse_module.name)

  let imports_result =
    glimpse_module.module.imports
    |> list.map(fn(definition) { definition.definition })
    |> list.fold_until(
      Ok(types.EnvState(environment, module_envs)),
      imports.fold_import_from_env,
    )

  use types.EnvState(environment, _) <- result.try(imports_result)

  use environment <- result.try(
    glimpse_module.module.type_aliases
    |> list.map(fn(d) { d.definition })
    |> list.try_fold(environment, type_alias),
  )

  use environment <- result.try(
    glimpse_module.module.custom_types
    |> list.try_fold(environment, fn(environment, glance_custom_type) {
      custom_type(environment, glance_custom_type.definition)
    }),
  )

  use constants_env_state <- result.try(
    glimpse_module.module.constants
    |> list.try_fold(types.EnvState(environment, []), fn(env_state, definition) {
      use constant_env_state <- result.try(constant(
        env_state.environment,
        definition.definition,
      ))
      Ok(
        types.EnvState(constant_env_state.environment, [
          definition,
          ..env_state.state
        ]),
      )
    }),
  )

  let constants = list.reverse(constants_env_state.state)
  let environment = constants_env_state.environment

  let function_signature_result =
    glimpse_module.module.functions
    |> list.map(fn(definition) { definition.definition })
    |> list.fold_until(Ok(environment), functions.function_signature)

  use environment <- result.try(function_signature_result)

  // Typecheck all function bodies twice. The first pass infers the callee
  // signatures (callers may see placeholder signatures for functions they call).
  // The second pass re-typechecks every body against the now-final signatures,
  // so callers get correct inferred types.
  use #(environment, _) <- result.try(typecheck_function_bodies(
    environment,
    glimpse_module.module.functions,
  ))
  use #(environment, functions) <- result.try(typecheck_function_bodies(
    environment,
    glimpse_module.module.functions,
  ))

  let new_glance_module =
    glance.Module(
      ..glimpse_module.module,
      functions: functions,
      constants: constants,
    )
  let new_glimpse_module =
    glimpse.Module(..glimpse_module, module: new_glance_module)
  Ok(#(new_glimpse_module, environment))
}

fn typecheck_function_bodies(
  environment: Environment,
  definitions: List(glance.Definition(glance.Function)),
) -> error.TypeCheckResult(
  #(Environment, List(glance.Definition(glance.Function))),
) {
  use functions_env_state <- result.try(
    definitions
    |> list.try_fold(types.EnvState(environment, []), fn(env_state, definition) {
      use function_env_state <- result.try(function(
        env_state.environment,
        definition.definition,
      ))
      let updated_definition =
        glance.Definition(..definition, definition: function_env_state.state)
      Ok(
        types.EnvState(function_env_state.environment, [
          updated_definition,
          ..env_state.state
        ]),
      )
    }),
  )

  Ok(#(functions_env_state.environment, list.reverse(functions_env_state.state)))
}

/// Register a type alias so that using the alias name in an annotation resolves
/// to the aliased type.
pub fn type_alias(
  environment: Environment,
  alias: glance.TypeAlias,
) -> EnvironmentResult {
  use resolved <- result.try(types.type_(environment, alias.aliased))
  let environment =
    types.Environment(
      ..environment,
      custom_types: dict.insert(environment.custom_types, alias.name, resolved),
    )
  let environment = case alias.publicity {
    glance.Public -> types.publish_custom_type_in_env(environment, alias.name)
    glance.Private -> environment
  }
  Ok(environment)
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
        environment
        |> types.add_custom_type_to_env(
          custom_type.name,
          custom_type.parameters,
        )

      let environment = case custom_type.publicity {
        glance.Public ->
          types.publish_custom_type_in_env(environment, custom_type.name)
        glance.Private -> environment
      }

      let environment_result =
        list.fold_until(
          custom_type.variants,
          Ok(types.EnvState(environment, custom_type)),
          functions.fold_variant_constructors_into_env,
        )
        |> result.map(types.extract_env)

      use environment <- result.try(environment_result)

      let environment = case custom_type.opaque_ {
        True ->
          list.fold(custom_type.variants, environment, fn(env, variant) {
            types.Environment(
              ..env,
              public_definitions: set.delete(
                env.public_definitions,
                variant.name,
              ),
            )
          })
        False -> environment
      }

      Ok(environment)
    }
  }
  // TODO: Also add variants
}

/// Typecheck a module constant's value and register it in the environment.
pub fn constant(
  environment: Environment,
  constant: glance.Constant,
) -> types.EnvStateResult(glance.Constant) {
  let store = types.new_type_store()
  use #(_store, value_type) <- result.try(intern.expression(
    environment,
    store,
    constant.value,
  ))

  let constant_type = case constant.annotation {
    option.None -> Ok(value_type)
    option.Some(annotation) ->
      types.type_(environment, annotation)
      |> result.try(fn(annotated) {
        case annotated == value_type {
          True -> Ok(annotated)
          False ->
            Error(error.InvalidAnnotation(
              types.to_string(environment, value_type),
              types.to_string(environment, annotated),
              constant.name,
            ))
        }
      })
  }

  use type_ <- result.try(constant_type)
  let environment =
    types.add_or_update_def_in_env(environment, constant.name, type_)
  let environment = case constant.publicity {
    glance.Public -> types.publish_def_in_env(environment, constant.name)
    glance.Private -> environment
  }
  Ok(types.EnvState(environment, constant))
}

/// Takes a glance function as input and returns the same function, but
/// with the inferred return type if the original function did not have
/// a return type. Returns an error if anything in the function doesn't
/// typecheck. The function signature in the environment may be updated
/// with an inferred return type.
pub fn function(
  environment: Environment,
  function: glance.Function,
) -> types.EnvStateResult(glance.Function) {
  let store = types.new_type_store()

  // Fold parameters into environment with fresh vars for unannotated private params
  use param_state <- result.try(
    list.fold_until(
      function.parameters
        |> list.index_map(fn(param, index) { #(index, param) }),
      Ok(
        functions.FunctionParamState(store, environment, function.publicity, []),
      ),
      fn(state, indexed_param) {
        let #(index, param) = indexed_param
        functions.fold_function_parameter_into_env(state, index, param)
      },
    ),
  )

  // Typecheck the function body with the threaded store
  use #(store, body_type) <- result.try(intern.block(
    param_state.environment,
    param_state.store,
    function.body,
  ))

  case function.return {
    option.None -> {
      // No return annotation: infer return type and parameter types
      // Resolve all inferred parameter types and the return type from the store
      let #(store, resolved_inferred) =
        list.fold(param_state.inferred, #(store, []), fn(state, item) {
          let #(index, var_type) = item
          let #(store, acc) = state
          let #(store, resolved) = types.resolve(store, var_type)
          #(store, [#(index, resolved), ..acc])
        })

      let #(store, resolved_return) = types.resolve(store, body_type)

      // Generalise all inferred params AND return type together for consistent naming
      let param_types =
        list.map(resolved_inferred, fn(item) {
          let #(_, t) = item
          t
        })
      let all_types = list.append(param_types, [resolved_return])
      let generalised_all = types.generalise_multi(store, all_types)

      // Split back into params and return
      let generalised_params =
        list.take(generalised_all, list.length(resolved_inferred))
      let generalised_return =
        list.last(generalised_all)
        |> result.unwrap(types.NilType)

      // Build resolved_inferred with generalised types
      let resolved_inferred =
        list.zip(resolved_inferred, generalised_params)
        |> list.map(fn(pair) {
          let #(#(index, _), gen_type) = pair
          #(index, gen_type)
        })

      // Build updated function with inferred parameter types
      let build_updated_param = fn(param: glance.FunctionParameter, index: Int) -> glance.FunctionParameter {
        let found =
          list.filter(resolved_inferred, fn(item) {
            case item {
              #(i, _) -> i == index
            }
          })
        case found {
          [#(_, inferred_type), ..] ->
            glance.FunctionParameter(
              ..param,
              type_: option.Some(types.to_glance(environment, inferred_type)),
            )
          [] -> param
        }
      }

      let updated_parameters =
        list.index_map(function.parameters, fn(param, index) {
          case param {
            glance.FunctionParameter(type_: option.None, ..) ->
              build_updated_param(param, index)
            _ -> param
          }
        })

      let updated_function =
        glance.Function(
          ..function,
          parameters: updated_parameters,
          return: option.Some(types.to_glance(environment, generalised_return)),
        )

      use updated_environment <- result.try(functions.update_function_signature(
        environment,
        updated_function,
      ))

      Ok(types.EnvState(updated_environment, updated_function))
    }
    option.Some(expected_type) -> {
      // Explicit return annotation: check that body type matches
      use expected <- result.try(types.type_(
        param_state.environment,
        expected_type,
      ))
      case types.unify(store, param_state.environment, body_type, expected) {
        Error(_) ->
          Error(error.InvalidReturnType(
            function.name,
            types.to_string(param_state.environment, body_type),
            types.to_string(param_state.environment, expected),
          ))
        Ok(_) -> Ok(types.EnvState(environment, function))
      }
    }
  }
}
