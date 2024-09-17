import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/string
import glimpse/internal/typecheck/environment.{
  type EnvStateFold, type EnvStateResult, type Environment,
}
import glimpse/internal/typecheck/types

/// Given a dict of a modules that have been previously typechecked,
/// and an import statement, add the environments of the module imported
/// by the given module to the environment.
pub fn fold_import_from_env(
  state: EnvStateResult(dict.Dict(String, Environment)),
  import_: glance.Import,
) -> EnvStateFold(dict.Dict(String, Environment)) {
  case state {
    Error(error) -> list.Stop(Error(error))
    Ok(environment.EnvState(environment, module_envs)) ->
      {
        case import_ {
          glance.Import(
            module,
            alias: option.None,
            unqualified_types: [],
            unqualified_values: [],
          ) -> {
            case dict.get(module_envs, module) {
              Error(_) ->
                panic as "Missing modules should have been detected before now  "
              Ok(module_env) -> {
                let assert Ok(namespace) =
                  string.split(module, "/") |> list.last

                Ok(environment.EnvState(
                  environment.add_def(
                    environment,
                    namespace,
                    types.NamespaceType(module_env.definitions),
                  ),
                  module_envs,
                ))
              }
            }
          }
          _ -> todo as "Complex imports not supported yet"
        }
      }
      |> list.Continue
  }
}
