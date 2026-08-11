import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import glimpse
import glimpse/error
import glimpse/internal/import_dependencies
import glimpse/internal/typecheck as intern
import glimpse/internal/typecheck/functions
import glimpse/internal/typecheck/imports
import glimpse/internal/typecheck/targets
import glimpse/internal/typecheck/types.{
  type Environment, type EnvironmentResult,
}
import glimpse/target

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
  target: target.Target,
) -> Result(glimpse.Package, error.GlimpseError(a)) {
  let import_graph =
    dict.map_values(package.modules, fn(_, value) { value.dependencies })

  use ordered_dependencies <- result.try(import_dependencies.sort_dependencies(
    import_graph,
    package.name,
  ))
  // A source module may not import a module that is only available as a
  // development dependency.
  use _ <- result.try(
    list.try_fold(ordered_dependencies, Nil, fn(_, module_name) {
      case
        !list.contains(package.dev_dependencies, module_name)
        && case dict.get(package.modules, module_name) {
          Ok(module) ->
            list.any(module.dependencies, fn(dep) {
              list.contains(package.dev_dependencies, dep)
            })
          Error(_) -> False
        }
      {
        True ->
          Error(error.ImportError(error.SrcImportingDevDependency(module_name)))
        False -> Ok(Nil)
      }
    }),
  )
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
              module(glimpse_module, module_envs, target, True)
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
/// `check_target_support` controls whether target support is enforced for this
/// module's definitions (pass `False` for dependencies, mirroring the real
/// compiler's `TargetSupport::NotEnforced`; pass `True` for the package being
/// checked, which additionally enables the use-site checks that reject calls
/// to functions with no implementation for the active target).
///
/// Returns a variation of the package where the module's contents have been
/// updated based on any inferences that were made.
pub fn module(
  glimpse_module: glimpse.Module,
  module_envs: dict.Dict(String, Environment),
  target: target.Target,
  check_target_support: Bool,
) -> error.TypeCheckResult(#(glimpse.Module, Environment)) {
  let environment =
    types.Environment(
      ..types.new_env(glimpse_module.name),
      target: target,
      check_target_support: check_target_support,
    )

  // The raw, unfiltered module. Attribute validation and the constant grammar
  // are parse-time checks in the real compiler, so they must run on every
  // definition even ones that are filtered out for the current build target
  // (e.g. a `@target(javascript)` constant with an anonymous-function value).
  let raw_module = glimpse_module.module

  // Drop definitions that are not active for the build target before
  // typechecking, mirroring the real compiler.
  let glimpse_module =
    glimpse.Module(
      ..glimpse_module,
      module: target.filter_for_target(glimpse_module.module, target),
    )

  // The constant grammar is validated before target filtering: a constant
  // value that is not a valid constant expression is a parse error in the real
  // compiler regardless of which target it is active for.
  use _ <- result.try(
    list.try_fold(raw_module.constants, Nil, fn(_, definition) {
      case constant_value_error(definition.definition.value) {
        option.Some(e) -> Error(e)
        option.None -> Ok(Nil)
      }
    }),
  )

  // Function and constant names share one namespace; the official compiler
  // rejects a module that defines the same name twice, in any combination.
  let definitions =
    glimpse_module.module.functions
    |> list.map(fn(definition) { definition.definition.name })
    |> list.append(
      glimpse_module.module.constants
      |> list.map(fn(definition) { definition.definition.name }),
    )
  use _ <- result.try(case intern.find_duplicate(definitions) {
    option.Some(name) -> Error(error.DuplicateDefinition(name))
    option.None -> Ok(Nil)
  })

  // Variant constructor names share a namespace with function and constant
  // names, so two custom types may not declare the same constructor even
  // though the type names themselves differ.
  let constructor_names =
    glimpse_module.module.custom_types
    |> list.map(fn(definition) { definition.definition })
    |> list.map(fn(custom_type) {
      custom_type.variants |> list.map(fn(variant) { variant.name })
    })
    |> list.flatten
  use _ <- result.try(case intern.find_duplicate(constructor_names) {
    option.Some(name) -> Error(error.DuplicateConstructor(name))
    option.None -> Ok(Nil)
  })

  // A public function with no body must have an `@external` implementation for
  // the active build target; otherwise it is unsupported on that target. The
  // real compiler reports `Unsupported target` for e.g. a public `@external`
  // function that only implements javascript while checking the erlang target.
  // Like the real compiler, this is enforced only for the package being
  // checked, not for its dependencies: a dependency's erlang-only externals
  // must not fail a javascript-target project, and vice versa.
  use _ <- result.try(case check_target_support {
    False -> Ok(Nil)
    True ->
      list.try_fold(glimpse_module.module.functions, Nil, fn(_, definition) {
        let glance_function = definition.definition
        case
          glance_function.publicity == glance.Public
          && glance_function.body == []
          && !target.function_supported(target, definition)
        {
          True -> Error(error.UnsupportedTarget(glance_function.name))
          False -> Ok(Nil)
        }
      })
  })

  // A function may not declare the same parameter name twice; the real
  // compiler rejects `fn start(conn, params, params)` at parse time with
  // "Argument name already used".
  use _ <- result.try(
    list.try_fold(glimpse_module.module.functions, Nil, fn(_, definition) {
      let parameter_names =
        definition.definition.parameters
        |> list.fold([], fn(names, param) {
          case param.name {
            glance.Named(name) -> [name, ..names]
            glance.Discarded(_) -> names
          }
        })
      case intern.find_duplicate(parameter_names) {
        option.Some(name) -> Error(error.DuplicateArgumentName(name))
        option.None -> Ok(Nil)
      }
    }),
  )

  // A custom type annotated `@external` may not declare constructors.
  use _ <- result.try(
    list.try_fold(glimpse_module.module.custom_types, Nil, fn(_, definition) {
      let glance_custom_type = definition.definition
      case
        list.any(definition.attributes, fn(attribute) {
          attribute.name == "external"
        })
        && glance_custom_type.variants != []
      {
        True ->
          Error(error.ExternalTypeWithConstructors(glance_custom_type.name))
        False -> Ok(Nil)
      }
    }),
  )

  // The Gleam compiler rejects attributes it does not recognise (`@foo(...)`,
  // or a misspelling like `@deprecated__zzz(...)`) at parse time. The only
  // valid attributes are `@external`, `@internal`, `@deprecated` and `@target`,
  // on functions, constants, custom types (including their variants and
  // fields), type aliases and imports.
  use _ <- result.try(
    list.fold(all_module_attributes(raw_module), Ok(Nil), fn(result, attribute) {
      case result, is_known_attribute(attribute.name) {
        Error(e), _ -> Error(e)
        Ok(_), True -> Ok(Nil)
        Ok(_), False -> Error(error.UnknownAttribute(attribute.name))
      }
    }),
  )

  // The Gleam compiler also checks each known attribute's argument shape:
  // `@deprecated` takes exactly one string message, `@target` exactly one
  // variable target, and `@internal` no arguments at all.
  use _ <- result.try(
    list.fold(all_module_attributes(raw_module), Ok(Nil), fn(result, attribute) {
      case result, attribute_shape_is_valid(attribute) {
        Error(e), _ -> Error(e)
        Ok(_), True -> Ok(Nil)
        Ok(_), False -> Error(error.InvalidAttributeShape(attribute.name))
      }
    }),
  )

  // An attribute may not be declared twice within one declaration scope. The
  // real compiler rejects `@deprecated("a") @deprecated("b")` on one function
  // with "Duplicate attribute".
  use _ <- result.try(
    case duplicate_attribute_name(attribute_scope_names(raw_module)) {
      option.Some(key) -> {
        let name = case string.starts_with(key, "external:") {
          True -> "external"
          False -> key
        }
        Error(error.DuplicateAttribute(name))
      }
      option.None -> Ok(Nil)
    },
  )

  // The Gleam compiler rejects `@external` attributes naming a build target it
  // does not know (`@external(rust, ...)`) at parse time; the only valid
  // targets are erlang and javascript. It also requires exactly three
  // arguments (target, module, function) with a `Variable` target.
  use _ <- result.try(
    raw_module.functions
    |> list.map(fn(definition) { definition.attributes })
    |> list.append(
      raw_module.constants
      |> list.map(fn(definition) { definition.attributes }),
    )
    |> list.flatten
    |> list.fold(Ok(Nil), fn(result, attribute) {
      case result, attribute.name == "external" {
        Error(e), _ -> Error(e)
        Ok(_), False -> Ok(Nil)
        Ok(_), True ->
          case attribute.arguments {
            [glance.Variable(_, name), glance.String(_, _), glance.String(_, _)] ->
              case name == "erlang" || name == "javascript" {
                True -> Ok(Nil)
                False -> Error(error.UnknownExternalTarget(name))
              }
            [glance.Variable(_, name), ..] ->
              case name == "erlang" || name == "javascript" {
                True -> Error(error.InvalidExternalAttribute)
                False -> Error(error.UnknownExternalTarget(name))
              }
            _ -> Error(error.InvalidExternalAttribute)
          }
      }
    }),
  )

  // The `@target` attribute is validated the same way: only the erlang and
  // javascript targets are recognised (`@target(python)` is a parse error in
  // the real compiler). The shape check above guarantees a single variable
  // argument, so a mismatched name is the only case to reject here.
  use _ <- result.try(
    list.fold(all_module_attributes(raw_module), Ok(Nil), fn(result, attribute) {
      case result, attribute.name == "target" {
        Error(e), _ -> Error(e)
        Ok(_), False -> Ok(Nil)
        Ok(_), True ->
          case attribute.arguments {
            [glance.Variable(_, name)] ->
              case name == "erlang" || name == "javascript" {
                True -> Ok(Nil)
                False -> Error(error.UnknownTarget(name))
              }
            _ -> Ok(Nil)
          }
      }
    }),
  )

  let imports_result =
    glimpse_module.module.imports
    |> list.map(fn(definition) { definition.definition })
    |> list.fold_until(
      Ok(types.EnvState(environment, module_envs)),
      imports.fold_import_from_env,
    )

  use types.EnvState(environment, _) <- result.try(imports_result)

  // Keep the full set of dependency module environments so field access can
  // resolve constructors of types from modules that were not explicitly
  // imported (the real compiler reads them from its `importable_modules`).
  let environment =
    types.Environment(
      ..environment,
      imports: types.Imports(
        ..environment.imports,
        module_environments: module_envs,
      ),
    )

  use environment <- result.try(
    glimpse_module.module.custom_types
    |> list.try_fold(environment, fn(environment, glance_custom_type) {
      custom_type_declaration(environment, glance_custom_type.definition)
    }),
  )

  use sorted_aliases <- result.try(sort_type_aliases(
    glimpse_module.module.type_aliases |> list.map(fn(d) { d.definition }),
  ))

  use environment <- result.try(
    sorted_aliases
    |> list.try_fold(environment, type_alias),
  )

  use environment <- result.try(
    glimpse_module.module.custom_types
    |> list.try_fold(environment, fn(environment, glance_custom_type) {
      custom_type_constructors(environment, glance_custom_type.definition)
    }),
  )

  use env_for_signatures <- result.try(
    glimpse_module.module.functions
    |> list.map(fn(definition) { definition.definition })
    |> list.try_fold(environment, check_public_signature_leaks),
  )
  let environment = env_for_signatures

  let function_signature_result =
    glimpse_module.module.functions
    |> list.map(fn(definition) { definition.definition })
    |> list.fold_until(Ok(environment), functions.function_signature)

  use environment <- result.try(function_signature_result)

  use constants_env_state <- result.try(
    glimpse_module.module.constants
    // glance prepends constants, so they are in reverse source order. Fold in
    // source order so earlier constants are in the environment when later
    // constants' values reference them.
    |> list.reverse
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

  let constants = constants_env_state.state
  let environment = constants_env_state.environment

  // Compute which targets this module's functions can run on *before* the
  // bodies are checked, so a body that calls a same-module function unsupported
  // on the active target is rejected at the call site, matching the real
  // compiler. The result is recomputed after the body passes for the returned
  // environment, since body checking clears the target support of any name a
  // local binding shadows.
  let environment =
    types.Environment(
      ..environment,
      target_support: targets.compute_module_target_support(
        environment,
        glimpse_module.module.functions,
      ),
    )

  // Typecheck all function bodies twice. The first pass infers the callee
  // signatures (callers may see placeholder signatures for functions they call).
  // The second pass re-typechecks every body against the now-final signatures,
  // so callers get correct inferred types.
  use #(environment, _) <- result.try(typecheck_function_bodies(
    types.set_defer_unknown(environment, True),
    glimpse_module.module.functions,
  ))
  use #(environment, functions) <- result.try(typecheck_function_bodies(
    types.set_defer_unknown(environment, False),
    glimpse_module.module.functions,
  ))

  // Compute which targets each of this module's functions can run on, so
  // callers in other modules can reject calls to functions that cannot run on
  // the active build target (e.g. an erlang-only external called from
  // javascript-target code). Dependencies are processed before their importers,
  // so imported modules' supports are already computed and reachable through
  // the module environments.
  let environment =
    types.Environment(
      ..environment,
      target_support: targets.compute_module_target_support(
        environment,
        functions,
      ),
    )

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

/// A public function may not reference a private custom type in its signature.
fn check_public_signature_leaks(
  environment: Environment,
  function: glance.Function,
) -> Result(Environment, error.TypeCheckError) {
  case function.publicity == glance.Public {
    False -> Ok(environment)
    True ->
      case
        find_private_type_in_types(environment, [
          function.return,
          ..find_params_types(function.parameters)
        ])
      {
        Ok(leak) -> Error(error.PrivateTypeLeak(leak))
        Error(_) -> Ok(environment)
      }
  }
}

fn find_params_types(
  parameters: List(glance.FunctionParameter),
) -> List(option.Option(glance.Type)) {
  list.map(parameters, fn(param) { param.type_ })
}

/// Checks a list of optional types and returns Ok(name) if any references a
/// private custom type of the current module.
fn find_private_type_in_types(
  environment: Environment,
  given_types: List(option.Option(glance.Type)),
) -> Result(String, Nil) {
  list.fold(given_types, Error(Nil), fn(prev, t) {
    case prev {
      Ok(_) -> prev
      Error(_) ->
        case t {
          option.None -> Error(Nil)
          option.Some(t) -> find_private_in_type(environment, t)
        }
    }
  })
}

/// Depth-first search for a private custom type reference within a single type
/// annotation.
fn find_private_in_type(
  environment: Environment,
  type_: glance.Type,
) -> Result(String, Nil) {
  case type_ {
    glance.NamedType(_, name, module, parameters) ->
      case module == option.None && is_private_local_type(environment, name) {
        True -> Ok(name)
        False -> find_private_in_types(environment, parameters)
      }
    glance.TupleType(_, elements) ->
      find_private_in_types(environment, elements)
    glance.FunctionType(_, parameters, ret) ->
      case find_private_in_type(environment, ret) {
        Ok(found) -> Ok(found)
        Error(_) -> find_private_in_types(environment, parameters)
      }
    glance.VariableType(_, _) | glance.HoleType(_, _) -> Error(Nil)
  }
}

/// A type reference is a private leak only if it names a custom type defined
/// in the current module that has not been published. Prelude types and
/// unqualified imports also live in `custom_types` but are defined elsewhere.
fn is_private_local_type(environment: Environment, name: String) -> Bool {
  case dict.get(environment.custom_types, name) {
    Ok(types.CustomType(defining_module, _, _, _)) ->
      defining_module == environment.current_module
      && !set.contains(environment.public_custom_types, name)
    _ -> False
  }
}

/// Like [find_private_type_in_types] but for non-optional types.
fn find_private_in_types(
  environment: Environment,
  types: List(glance.Type),
) -> Result(String, Nil) {
  list.fold(types, Error(Nil), fn(prev, t) {
    case prev {
      Ok(_) -> prev
      Error(_) -> find_private_in_type(environment, t)
    }
  })
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
      use function_env_state <- result.try(
        case definition.definition.body == [] {
          True ->
            Ok(types.EnvState(env_state.environment, definition.definition))
          False ->
            function(
              types.Environment(
                ..env_state.environment,
                current_function_external: targets.external_support(definition),
              ),
              definition.definition,
            )
        },
      )
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
/// Order a module's type aliases so that every alias is registered before any
/// alias that references it, mirroring the real compiler's topological sort of
/// alias dependencies. Aliases that reference each other in a cycle are an
/// error.
fn sort_type_aliases(
  aliases: List(glance.TypeAlias),
) -> error.TypeCheckResult(List(glance.TypeAlias)) {
  let alias_names =
    aliases |> list.map(fn(alias) { alias.name }) |> set.from_list
  let with_deps =
    list.map(aliases, fn(alias) {
      #(alias, alias_type_dependencies(alias.aliased, alias_names))
    })
  sort_alias_dependencies(with_deps)
}

fn sort_alias_dependencies(
  remaining: List(#(glance.TypeAlias, set.Set(String))),
) -> error.TypeCheckResult(List(glance.TypeAlias)) {
  let #(ready, rest) =
    list.partition(remaining, fn(pair) {
      let #(_, deps) = pair
      set.size(deps) == 0
    })
  case ready {
    [] ->
      case remaining {
        [] -> Ok([])
        [#(alias, _), ..] -> Error(error.RecursiveTypeAlias(alias.name))
      }
    _ -> {
      let ready_names =
        ready
        |> list.map(fn(pair) {
          let #(alias, _) = pair
          alias.name
        })
        |> set.from_list
      let stripped =
        list.map(rest, fn(pair) {
          let #(alias, deps) = pair
          #(alias, set.difference(deps, ready_names))
        })
      use rest_sorted <- result.try(sort_alias_dependencies(stripped))
      let ready_sorted =
        ready
        |> list.map(fn(pair) {
          let #(alias, _) = pair
          alias
        })
      Ok(list.append(ready_sorted, rest_sorted))
    }
  }
}

/// Collect the set of same-module type alias names referenced by a type
/// annotation. Only unqualified names can refer to a same-module alias.
fn alias_type_dependencies(
  type_: glance.Type,
  known: set.Set(String),
) -> set.Set(String) {
  let parameter_deps = fn(types: List(glance.Type)) {
    list.fold(types, set.new(), fn(acc, t) {
      set.union(acc, alias_type_dependencies(t, known))
    })
  }
  case type_ {
    glance.NamedType(_, name, option.None, parameters) ->
      case set.contains(known, name) {
        True -> set.insert(parameter_deps(parameters), name)
        False -> parameter_deps(parameters)
      }
    glance.NamedType(_, _, option.Some(_), parameters) ->
      parameter_deps(parameters)
    glance.TupleType(_, elements) -> parameter_deps(elements)
    glance.FunctionType(_, parameters, return_) ->
      parameter_deps(parameters)
      |> set.union(alias_type_dependencies(return_, known))
    glance.VariableType(_, _) | glance.HoleType(_, _) -> set.new()
  }
}

pub fn type_alias(
  environment: Environment,
  alias: glance.TypeAlias,
) -> EnvironmentResult {
  use _ <- result.try(case intern.find_duplicate(alias.parameters) {
    option.Some(name) -> Error(error.DuplicateTypeParameter(name))
    option.None -> Ok(Nil)
  })
  // Every declared type parameter must be used in the aliased type.
  case
    alias.parameters
    |> list.find(fn(parameter) {
      !type_uses_type_variable(alias.aliased, parameter)
    })
  {
    Ok(unused) -> Error(error.UnusedTypeParameter(unused))
    Error(_) ->
      case clash_with_existing(environment, alias.name) {
        True -> Error(error.DuplicateCustomType(alias.name))
        False -> {
          use resolved <- result.try(types.type_(environment, alias.aliased))
          let alias_type = types.TypeAlias(alias.parameters, resolved)
          let environment =
            types.Environment(
              ..environment,
              custom_types: dict.insert(
                environment.custom_types,
                alias.name,
                alias_type,
              ),
            )
          type_alias_publish(environment, alias)
        }
      }
  }
}

fn type_alias_publish(
  environment: Environment,
  alias: glance.TypeAlias,
) -> EnvironmentResult {
  let environment = case alias.publicity {
    glance.Public -> types.publish_custom_type_in_env(environment, alias.name)
    glance.Private -> environment
  }
  Ok(environment)
}

/// Whether a glance type annotation mentions a given type variable name.
fn type_uses_type_variable(type_: glance.Type, name: String) -> Bool {
  case type_ {
    glance.NamedType(_, _, _, parameters) ->
      list.any(parameters, type_uses_type_variable(_, name))
    glance.TupleType(_, elements) ->
      list.any(elements, fn(t) { type_uses_type_variable(t, name) })
    glance.FunctionType(_, parameters, return_) ->
      list.any(parameters, fn(t) { type_uses_type_variable(t, name) })
      || type_uses_type_variable(return_, name)
    glance.VariableType(_, variable) -> variable == name
    glance.HoleType(_, _) -> False
  }
}

/// A new declaration of `name` clashes with an existing definition unless the
/// existing entry is an implicit prelude type, which modules may shadow.
fn clash_with_existing(environment: Environment, name: String) -> Bool {
  case dict.get(environment.custom_types, name) {
    Ok(existing) -> !types.is_prelude_type(existing)
    Error(_) -> False
  }
}

/// Register a custom type's name and type parameters in the environment.
/// Constructors are registered separately (see `custom_type_constructors`) so
/// that types referencing each other resolve regardless of declaration order.
pub fn custom_type_declaration(
  environment: Environment,
  custom_type: glance.CustomType,
) -> EnvironmentResult {
  case clash_with_existing(environment, custom_type.name) {
    True -> Error(error.DuplicateCustomType(custom_type.name))
    False -> {
      use _ <- result.try(case intern.find_duplicate(custom_type.parameters) {
        option.Some(name) -> Error(error.DuplicateTypeParameter(name))
        option.None -> Ok(Nil)
      })
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
      Ok(environment)
    }
  }
}

/// Add all variant constructors of a custom type to the environment. Runs after
/// every custom type in the module has been declared so forward references in
/// variant fields resolve.
pub fn custom_type_constructors(
  environment: Environment,
  custom_type: glance.CustomType,
) -> EnvironmentResult {
  // Two variants may not share a constructor name.
  let names = custom_type.variants |> list.map(fn(variant) { variant.name })
  use _ <- result.try(case intern.find_duplicate(names) {
    option.Some(name) -> Error(error.DuplicateConstructor(name))
    option.None -> Ok(Nil)
  })
  // A constructor may not declare the same label twice.
  use _ <- result.try(
    list.try_fold(custom_type.variants, Nil, fn(_, variant) {
      let labels =
        variant.fields
        |> list.map(fn(field) {
          case field {
            glance.LabelledVariantField(_, label) -> label
            glance.UnlabelledVariantField(_) -> ""
          }
        })
        |> list.filter(fn(label) { label != "" })
      case intern.find_duplicate(labels) {
        option.Some(label) -> Error(error.DuplicateLabel(label))
        option.None -> Ok(Nil)
      }
    }),
  )
  // A field annotation may only reference type variables declared as
  // parameters of the custom type. Unlike a function signature, a custom type
  // does not introduce new type variables implicitly.
  use _ <- result.try(
    list.try_fold(custom_type.variants, Nil, fn(_, variant) {
      let used =
        variant.fields
        |> list.fold([], fn(acc, field) {
          case field {
            glance.LabelledVariantField(item: type_, label: _) ->
              list.append(acc, type_variables_used(type_))
            glance.UnlabelledVariantField(type_) ->
              list.append(acc, type_variables_used(type_))
          }
        })
      case intern.find_first_not_in(used, custom_type.parameters) {
        option.Some(name) -> Error(error.UnknownCustomType(name))
        option.None -> Ok(Nil)
      }
    }),
  )
  custom_type_constructors_(environment, custom_type)
}

/// The names of every `VariableType` occurring anywhere within a type
/// annotation, recursively. Used to check that a custom type's field
/// annotations only reference declared type parameters.
/// Collect every attribute attached anywhere in the module: on imports,
/// custom types (and their variants), type aliases, constants and functions.
fn all_module_attributes(module: glance.Module) -> List(glance.Attribute) {
  list.flatten([
    module.imports |> list.map(fn(d) { d.attributes }) |> list.flatten,
    module.custom_types
      |> list.map(fn(d) {
        list.flatten([
          d.attributes,
          d.definition.variants
            |> list.map(fn(variant) { variant.attributes })
            |> list.flatten,
        ])
      })
      |> list.flatten,
    module.type_aliases |> list.map(fn(d) { d.attributes }) |> list.flatten,
    module.constants |> list.map(fn(d) { d.attributes }) |> list.flatten,
    module.functions |> list.map(fn(d) { d.attributes }) |> list.flatten,
  ])
}

/// The attribute names attached to each declaration scope: one scope per
/// import, function, constant and type alias, and one scope per custom type
/// (a type and its variants share a scope, so `@deprecated` on the type and on
/// a variant is a duplicate). The real compiler rejects a scope that declares
/// the same attribute twice.
fn attribute_scope_names(module: glance.Module) -> List(List(String)) {
  let scopes =
    module.imports
    |> list.map(fn(d) { d.attributes })
    |> list.append(module.functions |> list.map(fn(d) { d.attributes }))
    |> list.append(module.constants |> list.map(fn(d) { d.attributes }))
    |> list.append(module.type_aliases |> list.map(fn(d) { d.attributes }))
    |> list.append(
      module.custom_types
      |> list.map(fn(d) {
        list.flatten([
          d.attributes,
          d.definition.variants
            |> list.map(fn(variant) { variant.attributes })
            |> list.flatten,
        ])
      }),
    )
  list.map(scopes, fn(attributes) { list.map(attributes, attribute_key) })
}

/// The key that determines whether two attributes are duplicates: the
/// attribute name, except that `@external` is keyed by its target (first
/// argument), since a function may have one `@external` per target.
fn attribute_key(attribute: glance.Attribute) -> String {
  case attribute.name {
    "external" ->
      case attribute.arguments {
        [glance.Variable(_, target_name), ..] -> "external:" <> target_name
        _ -> "external"
      }
    name -> name
  }
}

/// The name of an attribute declared twice within one declaration scope, if
/// any.
fn duplicate_attribute_name(
  scopes: List(List(String)),
) -> option.Option(String) {
  list.fold(scopes, option.None, fn(found, scope) {
    case found {
      option.Some(_) -> found
      option.None -> intern.find_duplicate(scope)
    }
  })
}

/// Whether an attribute name is one of the attributes the Gleam compiler
/// recognises: `@external`, `@internal`, `@deprecated` and `@target`.
fn is_known_attribute(name: String) -> Bool {
  list.contains(["external", "internal", "deprecated", "target"], name)
}

/// Whether an attribute's arguments match the shape the Gleam compiler
/// expects: `@external` is checked separately (target name + three arguments);
/// `@deprecated` takes one string message, `@target` one variable target, and
/// `@internal` no arguments at all.
fn attribute_shape_is_valid(attribute: glance.Attribute) -> Bool {
  case attribute.name, attribute.arguments {
    "external", _ -> True
    "deprecated", [glance.String(_, _)] -> True
    "target", [glance.Variable(_, _)] -> True
    "internal", [] -> True
    _, _ -> False
  }
}

fn type_variables_used(type_: glance.Type) -> List(String) {
  case type_ {
    glance.NamedType(_, _, _, parameters) ->
      list.flatten(list.map(parameters, type_variables_used))
    glance.TupleType(_, elements) ->
      list.flatten(list.map(elements, type_variables_used))
    glance.FunctionType(_, parameters, return) ->
      list.flatten(list.map(parameters, type_variables_used))
      |> list.append(type_variables_used(return))
    glance.VariableType(_, name) -> [name]
    glance.HoleType(_, _) -> []
  }
}

fn custom_type_constructors_(
  environment: Environment,
  custom_type: glance.CustomType,
) -> EnvironmentResult {
  let environment_result =
    list.index_fold(
      custom_type.variants,
      Ok(types.EnvState(environment, custom_type)),
      fn(state, variant, index) {
        case state {
          Error(error) -> Error(error)
          Ok(_) ->
            functions.fold_variant_constructor_into_env(state, variant, index)
        }
      },
    )
    |> result.map(types.extract_env)

  use environment <- result.try(environment_result)

  let environment = case custom_type.opaque_ {
    True ->
      list.fold(custom_type.variants, environment, fn(env, variant) {
        types.Environment(
          ..env,
          scope: types.Scope(
            ..env.scope,
            public_definitions: set.delete(
              env.scope.public_definitions,
              variant.name,
            ),
          ),
        )
      })
    False -> environment
  }

  Ok(environment)
}

/// Typecheck a module constant's value and register it in the environment.
pub fn constant(
  environment: Environment,
  constant: glance.Constant,
) -> types.EnvStateResult(glance.Constant) {
  // Constants are restricted to a subset of the expression grammar (the real
  // compiler parses them with a dedicated grammar): literal values, references
  // to other constants, list/tuple/bit-array literals, record construction and
  // updates, string concatenation, and nothing else. `todo`, `panic`,
  // anonymous functions, operators, blocks, `case`, captures and field access
  // are all rejected.
  case constant_value_error(constant.value) {
    option.Some(e) -> Error(e)
    option.None -> constant_(environment, constant)
  }
}

/// Whether a constant value expression violates the constant grammar, and if
/// so which error to report. `None` means the value is a valid constant.
fn constant_value_error(
  expr: glance.Expression,
) -> option.Option(error.TypeCheckError) {
  case expr {
    // `todo` and `panic` are not allowed in constants at all.
    glance.Todo(_, _) -> option.Some(error.TodoInConstant)
    glance.Panic(_, _) -> option.Some(error.InvalidConstantExpression)
    glance.Fn(_, _, _, _) -> option.Some(error.FnInConstant)
    // Literals and constant references.
    glance.Int(_, _)
    | glance.Float(_, _)
    | glance.String(_, _)
    | glance.Variable(_, _) -> option.None
    // String concatenation is the only allowed binary operator.
    glance.BinaryOperator(_, glance.Concatenate, left, right) ->
      case constant_value_error(left) {
        option.Some(e) -> option.Some(e)
        option.None -> constant_value_error(right)
      }
    glance.BinaryOperator(_, _, _, _) ->
      option.Some(error.InvalidConstantExpression)
    // Negation is lexed as part of a numeric literal, so a standalone
    // `NegateInt`/`NegateBool` (e.g. `-x`, `!True`) is not a constant.
    glance.NegateInt(_, _) | glance.NegateBool(_, _) ->
      option.Some(error.InvalidConstantExpression)
    // Blocks, `case`, captures, tuple index and echo are not constants.
    glance.Block(_, _)
    | glance.Case(_, _, _)
    | glance.FnCapture(_, _, _, _, _)
    | glance.TupleIndex(_, _, _)
    | glance.Echo(_, _, _) -> option.Some(error.InvalidConstantExpression)
    glance.FieldAccess(_, container, _) ->
      // `module.name` is a qualified reference to another module's constant;
      // any other field access (e.g. `R(1).a`) is not a constant.
      case container {
        glance.Variable(_, _) -> option.None
        _ -> option.Some(error.InvalidConstantExpression)
      }
    glance.Tuple(_, elements) -> constant_value_list_error(elements)
    glance.List(_, [], option.Some(_)) ->
      option.Some(error.InvalidConstantExpression)
    glance.List(_, elements, rest) ->
      case constant_value_list_error(elements) {
        option.Some(e) -> option.Some(e)
        option.None ->
          case rest {
            option.Some(r) -> constant_value_error(r)
            option.None -> option.None
          }
      }
    glance.Call(_, function, arguments) -> {
      // A call is a record construction when the callee is a plain constructor
      // reference (upper-case name, possibly module-qualified). Any other call
      // (a lower-case function name) is a function call, which is not allowed.
      let callee_ok = case function {
        glance.Variable(_, name) -> is_constructor_name(name)
        glance.FieldAccess(_, glance.Variable(_, _), label) ->
          is_constructor_name(label)
        _ -> False
      }
      case callee_ok {
        False -> option.Some(error.InvalidConstantExpression)
        True ->
          constant_value_list_error(
            list.map(arguments, fn(field) { field_item(field) }),
          )
      }
    }
    glance.RecordUpdate(_, _, _, record, fields) ->
      case constant_value_error(record) {
        option.Some(e) -> option.Some(e)
        option.None ->
          constant_value_list_error(
            fields
            |> list.map(fn(field) {
              case field {
                glance.RecordUpdateField(_, option.Some(item)) -> [item]
                glance.RecordUpdateField(_, option.None) -> []
              }
            })
            |> list.flatten,
          )
      }
    glance.BitString(_, segments) ->
      constant_value_list_error(list.map(segments, fn(pair) { pair.0 }))
  }
}

fn constant_value_list_error(
  expressions: List(glance.Expression),
) -> option.Option(error.TypeCheckError) {
  case expressions {
    [] -> option.None
    [first, ..rest] ->
      case constant_value_error(first) {
        option.Some(e) -> option.Some(e)
        option.None -> constant_value_list_error(rest)
      }
  }
}

fn field_item(field: glance.Field(glance.Expression)) -> glance.Expression {
  case field {
    glance.LabelledField(_, _, item) -> item
    glance.UnlabelledField(item) -> item
    // A shorthand field (`Foo(name)` in a construction) references a variable,
    // which is a valid constant value.
    glance.ShorthandField(label, _) -> glance.Variable(glance.Span(0, 0), label)
  }
}

fn is_constructor_name(name: String) -> Bool {
  case string.first(name) {
    Ok(first) -> string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", first)
    Error(_) -> False
  }
}

fn constant_(
  environment: Environment,
  constant: glance.Constant,
) -> types.EnvStateResult(glance.Constant) {
  let store = types.new_type_store()
  use #(store, value_type) <- result.try(intern.expression(
    environment,
    store,
    constant.value,
  ))

  let constant_type_result = case constant.annotation {
    option.None -> Ok(#(store, value_type))
    option.Some(annotation) ->
      types.type_with_store(environment, store, annotation)
      |> result.try(fn(state) {
        let #(store, annotated) = state
        case types.unify(store, environment, value_type, annotated) {
          Ok(store) -> Ok(#(store, annotated))
          Error(_) -> {
            let #(_store, resolved) = types.resolve(store, value_type)
            Error(error.InvalidAnnotation(
              types.to_string(environment, resolved),
              types.to_string(environment, annotated),
              constant.name,
            ))
          }
        }
      })
  }

  use #(store, type_) <- result.try(constant_type_result)
  let #(_store, generalised) = types.resolve_and_generalise(store, type_)
  let environment =
    types.add_or_update_def_in_env(environment, constant.name, generalised)
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
  let store = types.seed_generic_edges(types.new_type_store(), environment)

  // Fold parameters into environment with fresh vars for unannotated private params
  use param_state <- result.try(
    list.fold_until(
      function.parameters
        |> list.index_map(fn(param, index) { #(index, param) }),
      Ok(functions.FunctionParamState(
        store,
        environment,
        function.publicity,
        [],
        dict.new(),
        function.name,
      )),
      fn(state, indexed_param) {
        let #(index, param) = indexed_param
        functions.fold_function_parameter_into_env(state, index, param)
      },
    ),
  )

  // Typecheck the function body with the threaded store
  use #(store, body_type) <- result.try(intern.block(
    types.Environment(
      ..param_state.environment,
      generic_vars: param_state.generic_vars,
      current_function: option.Some(function.name),
    ),
    param_state.store,
    function.body,
  ))
  // A return type that embeds a nested call to the function itself is
  // infinitely recursive (e.g. `f(xs) { case xs { [h, ..t] -> [f(t)] } }`);
  // a return that merely *is* a call to the function is fine.
  case types.nested_var_has_source(store, body_type, "r_" <> function.name) {
    True -> Error(error.RecursiveType)
    False -> {
      let environment = types.flush_generic_edges(environment, store)

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

          // The body called a same-module function earlier in source order whose
          // inferred return is still the `InferredReturn` placeholder during the
          // first pass, or returned the tagged `r_`-variable of a placeholder
          // call. Keep this function's placeholder signature; the second pass
          // re-checks it against the callee's now-final return. A function whose
          // return is the *own* `r_<self>` marker (a direct recursive call that
          // also unifies with its parameter types) is finite and can be
          // finalised here, so recursive helpers like `max_loop` get a real
          // signature instead of the `todo` wildcard they start with.
          let placeholder_return =
            resolved_return == types.InferredReturn
            || case types.var_source(store, resolved_return) {
              option.Some(name) ->
                string.starts_with(name, "r_") && name != "r_" <> function.name
              option.None -> False
            }
          case placeholder_return {
            True -> Ok(types.EnvState(environment, function))

            False -> {
              // Generalise all inferred params AND return type together for consistent naming
              let param_types =
                list.map(resolved_inferred, fn(item) {
                  let #(_, t) = item
                  t
                })
              let all_types = list.append(param_types, [resolved_return])
              let generalised_all = types.generalise_multi(store, all_types)
              let generalised_all =
                types.rename_parameter_generics(
                  function.name,
                  list.map(function.parameters, fn(param) {
                    param.type_ == option.None
                  }),
                  generalised_all,
                )

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
              let build_updated_param = fn(
                param: glance.FunctionParameter,
                index: Int,
              ) -> glance.FunctionParameter {
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
                      // Only write the annotation back when the type can be
                      // expressed in the module's own imports; otherwise leave the
                      // param unannotated and let the next pass re-infer it.
                      type_: case types.can_render(environment, inferred_type) {
                        True ->
                          option.Some(types.to_glance(
                            environment,
                            inferred_type,
                          ))
                        False -> option.None
                      },
                    )
                  [] -> param
                }
              }

              let updated_parameters =
                list.index_map(function.parameters, fn(param, index) {
                  build_updated_param(param, index)
                })

              let updated_function =
                glance.Function(
                  ..function,
                  parameters: updated_parameters,
                  // Only write the inferred return back when the type can be
                  // expressed in the module's own imports; otherwise leave the
                  // original annotation (or none) in place.
                  return: case
                    types.can_render(environment, generalised_return)
                  {
                    True ->
                      option.Some(types.to_glance(
                        environment,
                        generalised_return,
                      ))
                    False -> function.return
                  },
                )

              use updated_environment <- result.try(
                functions.update_function_signature(
                  environment,
                  updated_function,
                ),
              )

              Ok(types.EnvState(updated_environment, updated_function))
            }
          }
        }
        option.Some(expected_type) -> {
          // Explicit return annotation: check that body type matches. The
          // annotation's type variables are made rigid like the parameters'
          // (via the same `generic_vars`), so a return of `fn(b) -> b` cannot
          // adopt the body's distinct rigid `a`.
          use #(store, expected) <- result.try(types.type_with_store(
            param_state.environment,
            store,
            expected_type,
          ))
          let #(store, _generic_vars, expected) =
            functions.freshen_generics(
              store,
              param_state.generic_vars,
              expected,
            )
          case
            types.unify(store, param_state.environment, body_type, expected)
          {
            Error(_) -> {
              let #(store, resolved_body) = types.resolve(store, body_type)
              let #(_store, resolved_expected) = types.resolve(store, expected)
              Error(error.InvalidReturnType(
                function.name,
                types.to_string(param_state.environment, resolved_body),
                types.to_string(param_state.environment, resolved_expected),
              ))
            }
            Ok(store) -> {
              // An explicit return annotation with `_` holes means the holes
              // are fresh inference variables that unify with the body's
              // concrete return type. Write the resolved type back into the
              // stored signature so callers (e.g. a `use` statement pattern
              // checked against this function's return) see the concrete type
              // rather than an unbound variable. Without holes the annotation
              // already matches the body, so the signature is left untouched
              // (preserving the original source spans).
              //
              // Inferred parameter types are always written back: an
              // unannotated parameter's type is learned from the body (e.g. a
              // parameter returned directly becomes the return type), and
              // callers must check their arguments against that inferred type.
              let #(store, resolved_inferred) =
                list.fold(param_state.inferred, #(store, []), fn(state, item) {
                  let #(index, var_type) = item
                  let #(store, acc) = state
                  let #(store, resolved) = types.resolve(store, var_type)
                  #(store, [#(index, resolved), ..acc])
                })

              let build_updated_param = fn(
                param: glance.FunctionParameter,
                index: Int,
              ) -> glance.FunctionParameter {
                // Only unannotated parameters get their inferred type written
                // back; annotated parameters already carry a (possibly generic)
                // annotation whose source spans must be preserved.
                case param.type_ {
                  option.Some(_) -> param
                  option.None -> {
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
                          // Only write the annotation back when the type can be
                          // expressed in the module's own imports; otherwise
                          // leave the param unannotated and let the next pass
                          // re-infer it.
                          type_: case
                            types.can_render(environment, inferred_type)
                          {
                            True ->
                              option.Some(types.to_glance(
                                environment,
                                inferred_type,
                              ))
                            False -> option.None
                          },
                        )
                      [] -> param
                    }
                  }
                }
              }

              let updated_parameters =
                list.index_map(function.parameters, fn(param, index) {
                  build_updated_param(param, index)
                })
              let function =
                glance.Function(..function, parameters: updated_parameters)

              case types.type_contains_hole(expected_type) {
                False -> {
                  use updated_environment <- result.try(
                    functions.update_function_signature(environment, function),
                  )
                  Ok(types.EnvState(updated_environment, function))
                }
                True -> {
                  let #(_store, resolved_return) =
                    types.resolve(store, expected)
                  let updated_function =
                    glance.Function(
                      ..function,
                      return: case
                        types.can_render(environment, resolved_return)
                      {
                        True ->
                          option.Some(types.to_glance(
                            environment,
                            resolved_return,
                          ))
                        False -> function.return
                      },
                    )
                  use updated_environment <- result.try(
                    functions.update_function_signature(
                      environment,
                      updated_function,
                    ),
                  )
                  Ok(types.EnvState(updated_environment, updated_function))
                }
              }
            }
          }
        }
      }
    }
  }
}
