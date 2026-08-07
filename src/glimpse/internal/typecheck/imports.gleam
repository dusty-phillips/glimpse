import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import glimpse/error
import glimpse/internal/typecheck/types.{
  type EnvStateFold, type EnvStateResult, type Environment,
}

/// Given a dict of a modules that have been previously typechecked,
/// and an import statement, add the environments of the module imported
/// by the given module to the environment.
pub fn fold_import_from_env(
  state: EnvStateResult(dict.Dict(String, Environment)),
  import_: glance.Import,
) -> EnvStateFold(dict.Dict(String, Environment)) {
  case state {
    Error(error) -> list.Stop(Error(error))
    Ok(types.EnvState(environment, module_envs)) -> {
      let glance.Import(_, module, alias, unqualified_types, unqualified_values) =
        import_

      let namespace = case alias {
        option.Some(glance.Named(name)) -> name
        _ -> result.unwrap(string.split(module, "/") |> list.last, module)
      }

      let add_namespace = case alias {
        option.Some(glance.Discarded(_)) -> False
        _ -> True
      }

      let module_env = case module {
        _ if module == "gleam" || module == "prelude" ->
          option.Some(types.prelude_module_env(module))
        _ ->
          dict.get(module_envs, module)
          |> result.map(option.Some)
          |> result.unwrap(option.None)
      }

      case module_env {
        option.None -> list.Stop(Error(error.InvalidName(module)))
        option.Some(module_env) -> {
          let environment_result = {
            use _ <- result.try(
              case
                add_namespace
                && dict.has_key(environment.module_imports, namespace)
              {
                True -> Error(error.DuplicateImport(namespace))
                False -> Ok(Nil)
              },
            )
            use environment <- result.try(fold_values_into_env(
              environment,
              module_env,
              unqualified_values,
            ))
            use environment <- result.try(fold_types_into_env(
              environment,
              module_env,
              unqualified_types,
            ))

            let namespace_type =
              types.NamespaceType(
                module_env.definitions
                  |> dict.filter(fn(key, _) {
                    set.contains(module_env.public_definitions, key)
                  }),
                module_env.custom_types
                  |> dict.filter(fn(key, _) {
                    set.contains(module_env.public_custom_types, key)
                  }),
              )

            // The namespace lives only in `module_imports`, never in
            // `definitions`, so an unqualified-imported value (e.g.
            // `import element.{element}`) keeps resolving for bare calls while
            // `element.element` falls back to module access.
            let environment = case add_namespace {
              True ->
                environment
                |> types.add_or_update_namespace_in_env(
                  namespace,
                  namespace_type,
                )
              False -> environment
            }

            Ok(types.add_import_mapping_to_env(environment, module, namespace))
          }

          case environment_result {
            Error(error) -> list.Stop(Error(error))
            Ok(environment) ->
              types.EnvState(environment, module_envs) |> Ok |> list.Continue
          }
        }
      }
    }
  }
}

fn fold_values_into_env(
  environment: Environment,
  module_env: Environment,
  unqualified_values: List(glance.UnqualifiedImport),
) -> error.TypeCheckResult(Environment) {
  list.try_fold(
    unqualified_values,
    environment,
    fn(environment, unqualified_import) {
      let glance.UnqualifiedImport(name, import_alias) = unqualified_import
      case set.contains(module_env.public_definitions, name) {
        False -> Error(error.InvalidName(name))
        True -> {
          let scope_name = option.unwrap(import_alias, name)
          case dict.get(module_env.definitions, name) {
            Error(_) -> Error(error.InvalidName(name))
            Ok(type_) ->
              Ok(types.add_or_update_def_in_env(environment, scope_name, type_))
          }
        }
      }
    },
  )
}

fn fold_types_into_env(
  environment: Environment,
  module_env: Environment,
  unqualified_types: List(glance.UnqualifiedImport),
) -> error.TypeCheckResult(Environment) {
  list.try_fold(
    unqualified_types,
    environment,
    fn(environment, unqualified_import) {
      let glance.UnqualifiedImport(name, import_alias) = unqualified_import
      case set.contains(module_env.public_custom_types, name) {
        False -> Error(error.InvalidName(name))
        True -> {
          let scope_name = option.unwrap(import_alias, name)
          case dict.get(module_env.custom_types, name) {
            Error(_) -> Error(error.InvalidName(name))
            Ok(type_) ->
              Ok(types.add_or_update_custom_type_in_env(
                environment,
                scope_name,
                type_,
              ))
          }
        }
      }
    },
  )
}
