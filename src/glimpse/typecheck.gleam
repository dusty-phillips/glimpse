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
import glimpse/internal/target
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
  target: target.Target,
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
              module(glimpse_module, module_envs, target)
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
  target: target.Target,
) -> error.TypeCheckResult(#(glimpse.Module, Environment)) {
  let environment = types.new_env(glimpse_module.name)

  // Drop definitions that are not active for the build target before
  // typechecking, mirroring the real compiler.
  let glimpse_module =
    glimpse.Module(
      ..glimpse_module,
      module: target.filter_for_target(glimpse_module.module, target),
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
  use _ <- result.try(case list_has_duplicate(definitions) {
    Ok(name) -> Error(error.DuplicateDefinition(name))
    Error(_) -> Ok(Nil)
  })

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
    types.Environment(..environment, module_environments: module_envs)

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

  // A public function implemented only for other targets cannot be imported
  // on this one.
  use _ <- result.try(
    list.try_fold(glimpse_module.module.functions, Nil, fn(_, definition) {
      case
        definition.definition.publicity == glance.Public
        && !target.function_supported(target, definition)
      {
        True -> Error(error.UnsupportedTarget(definition.definition.name))
        False -> Ok(Nil)
      }
    }),
  )

  let function_signature_result =
    glimpse_module.module.functions
    |> list.filter(fn(definition) {
      target.function_supported(target, definition)
    })
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

fn is_external(definition: glance.Definition(glance.Function)) -> Bool {
  list.any(definition.attributes, fn(attribute) { attribute.name == "external" })
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
      use function_env_state <- result.try(case is_external(definition) {
        True -> Ok(types.EnvState(env_state.environment, definition.definition))
        False -> function(env_state.environment, definition.definition)
      })
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
  use _ <- result.try(case list_has_duplicate(alias.parameters) {
    Ok(name) -> Error(error.DuplicateTypeParameter(name))
    Error(_) -> Ok(Nil)
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
      case dict.has_key(environment.custom_types, alias.name) {
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

/// Register a custom type's name and type parameters in the environment.
/// Constructors are registered separately (see `custom_type_constructors`) so
/// that types referencing each other resolve regardless of declaration order.
pub fn custom_type_declaration(
  environment: Environment,
  custom_type: glance.CustomType,
) -> EnvironmentResult {
  case dict.has_key(environment.custom_types, custom_type.name) {
    True -> Error(error.DuplicateCustomType(custom_type.name))
    False -> {
      use _ <- result.try(case list_has_duplicate(custom_type.parameters) {
        Ok(name) -> Error(error.DuplicateTypeParameter(name))
        Error(_) -> Ok(Nil)
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
  use _ <- result.try(case list_has_duplicate(names) {
    Ok(name) -> Error(error.DuplicateConstructor(name))
    Error(_) -> Ok(Nil)
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
      case list_has_duplicate(labels) {
        Ok(label) -> Error(error.DuplicateLabel(label))
        Error(_) -> Ok(Nil)
      }
    }),
  )
  custom_type_constructors_(environment, custom_type)
}

fn list_has_duplicate(names: List(String)) -> Result(String, Nil) {
  let #(_seen, found) =
    list.fold(names, #(set.new(), option.None), fn(state, name) {
      let #(seen, found) = state
      case found {
        option.Some(_) -> state
        option.None ->
          case set.contains(seen, name) {
            True -> #(seen, option.Some(name))
            False -> #(set.insert(seen, name), option.None)
          }
      }
    })
  case found {
    option.Some(name) -> Ok(name)
    option.None -> Error(Nil)
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
          public_definitions: set.delete(env.public_definitions, variant.name),
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
  // `todo` and `panic` expressions are not allowed in constants.
  case constant_has_todo(constant.value) {
    True -> Error(error.TodoInConstant)
    False -> constant_(environment, constant)
  }
}

fn constant_(
  environment: Environment,
  constant: glance.Constant,
) -> types.EnvStateResult(glance.Constant) {
  let store = types.new_type_store()
  use #(_store, value_type) <- result.try(intern.expression(
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
          Error(_) ->
            Error(error.InvalidAnnotation(
              types.to_string(environment, value_type),
              types.to_string(environment, annotated),
              constant.name,
            ))
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

/// Whether an expression (recursively) contains a `todo`. Constants may not
/// reference `todo`.
fn constant_has_todo(expr: glance.Expression) -> Bool {
  case expr {
    glance.Todo(_, _) -> True
    glance.Int(_, _)
    | glance.Float(_, _)
    | glance.String(_, _)
    | glance.Variable(_, _)
    | glance.Panic(_, _) -> False
    glance.NegateInt(_, inner) -> constant_has_todo(inner)
    glance.NegateBool(_, inner) -> constant_has_todo(inner)
    glance.Block(_, statements) ->
      list.any(statements, fn(statement) { statement_has_todo(statement) })
    glance.Tuple(_, elements) -> list.any(elements, constant_has_todo)
    glance.List(_, elements, rest) ->
      list.any(elements, constant_has_todo)
      || case rest {
        option.Some(r) -> constant_has_todo(r)
        option.None -> False
      }
    glance.Fn(_, _, _, body) ->
      list.any(body, fn(statement) { statement_has_todo(statement) })
    glance.RecordUpdate(_, _, _, record, fields) ->
      constant_has_todo(record)
      || list.any(fields, fn(field) {
        case field {
          glance.RecordUpdateField(_, option.Some(item)) ->
            constant_has_todo(item)
          glance.RecordUpdateField(_, option.None) -> False
        }
      })
    glance.FieldAccess(_, container, _) -> constant_has_todo(container)
    glance.Call(_, function, arguments) ->
      constant_has_todo(function) || list.any(arguments, field_has_todo)
    glance.TupleIndex(_, tuple, _) -> constant_has_todo(tuple)
    glance.FnCapture(_, _, function, before, after) ->
      constant_has_todo(function)
      || list.any(before, field_has_todo)
      || list.any(after, field_has_todo)
    glance.BitString(_, segments) ->
      list.any(segments, fn(pair) {
        let #(value, options) = pair
        constant_has_todo(value)
        || list.any(options, fn(option) {
          case option {
            glance.SizeValueOption(inner) -> constant_has_todo(inner)
            _ -> False
          }
        })
      })
    glance.Case(_, subjects, clauses) ->
      list.any(subjects, constant_has_todo)
      || list.any(clauses, fn(clause) {
        constant_has_todo(clause.body)
        || case clause.guard {
          option.Some(guard) -> constant_has_todo(guard)
          option.None -> False
        }
      })
    glance.BinaryOperator(_, _, left, right) ->
      constant_has_todo(left) || constant_has_todo(right)
    glance.Echo(_, echoed, message) ->
      case echoed {
        option.Some(e) -> constant_has_todo(e)
        option.None ->
          case message {
            option.Some(m) -> constant_has_todo(m)
            option.None -> False
          }
      }
  }
}

fn statement_has_todo(statement: glance.Statement) -> Bool {
  case statement {
    glance.Use(_, _, function) -> constant_has_todo(function)
    glance.Assignment(_, _, _, _, value) -> constant_has_todo(value)
    glance.Assert(_, expression_, _) -> constant_has_todo(expression_)
    glance.Expression(expression_) -> constant_has_todo(expression_)
  }
}

fn field_has_todo(field: glance.Field(glance.Expression)) -> Bool {
  case field {
    glance.UnlabelledField(expr) -> constant_has_todo(expr)
    glance.LabelledField(_, _, expr) -> constant_has_todo(expr)
    glance.ShorthandField(_, _) -> False
  }
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
    param_state.environment,
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
          // re-checks it against the callee's now-final return.
          let placeholder_return =
            resolved_return == types.InferredReturn
            || case types.var_source(store, resolved_return) {
              option.Some(name) -> string.starts_with(name, "r_")
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
          // Explicit return annotation: check that body type matches
          use #(store, expected) <- result.try(types.type_with_store(
            param_state.environment,
            store,
            expected_type,
          ))
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
            Ok(_) -> Ok(types.EnvState(environment, function))
          }
        }
      }
    }
  }
}
