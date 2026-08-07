import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import glimpse/error
import glimpse/internal/typecheck/types.{
  type EnvStateResult, type Environment, type EnvironmentFold,
  type EnvironmentResult, type Type, type TypeStore,
}

pub type CallableState {
  CallableState(
    environment: Environment,
    reversed_by_position: List(Type),
    labels: dict.Dict(String, Int),
    /// Counter for generating unique generic type variable names for unannotated params
    generic_var_counter: Int,
    /// The name of the function whose signature is being built, used to keep
    /// unannotated parameter variables distinct across functions so cross
    /// function type constraints can be traced.
    function_name: String,
  )
}

pub type CallableStateResult =
  error.TypeCheckResult(CallableState)

pub type CallableStateFold =
  error.TypeCheckFold(CallableState)

pub fn empty_state(
  environment: Environment,
  function_name: String,
) -> CallableState {
  CallableState(environment, [], dict.new(), 0, function_name)
}

pub fn has_generic_types(types: List(Type)) -> Bool {
  list.any(types, is_generic_type)
}

pub fn is_generic_type(type_: Type) -> Bool {
  case type_ {
    types.GenericTypeVariable(_) -> True
    types.CustomType(_, _, parameters, _) ->
      list.any(parameters, is_generic_type)
    types.TupleType(elements) -> list.any(elements, is_generic_type)
    types.CallableType(parameters, _, return) ->
      has_generic_types(parameters) || is_generic_type(return)
    types.GenericCallableType(parameters, _, return, _) ->
      has_generic_types(parameters) || is_generic_type(return)
    _ -> False
  }
}

pub fn to_callable_type_with_original(
  state: CallableState,
  return_type: Type,
  original_function: glance.Function,
) -> Type {
  let parameters = state.reversed_by_position |> list.reverse
  case has_generic_types(parameters) || is_generic_type(return_type) {
    True ->
      types.GenericCallableType(
        parameters,
        state.labels,
        return_type,
        original_function,
      )
    False -> types.CallableType(parameters, state.labels, return_type)
  }
}

/// Update environment with function signature. Non-fold version.
pub fn update_function_signature(
  environment: Environment,
  function: glance.Function,
) -> EnvironmentResult {
  use param_state <- result.try(
    function.parameters
    |> list.fold_until(
      Ok(empty_state(environment, function.name)),
      fold_parameter_into_callable(),
    ),
  )

  let return_type = case function.return {
    option.None -> {
      // If a function has unannotated params (detected by generic vars in params),
      // use the `todo` wildcard for return. It unifies with anything, so calls to
      // this function (including recursive calls) can resolve their argument types
      // during the signature phase. It is replaced with the real return type once
      // the body is checked.
      case has_generic_types(param_state.reversed_by_position) {
        True -> Ok(types.GenericTypeVariable("todo"))
        False -> Ok(types.InferredReturn)
      }
    }
    option.Some(glance_return_type) ->
      types.type_with_holes(
        environment,
        param_state.generic_var_counter,
        glance_return_type,
      )
      |> result.map(fn(result) {
        let #(_next_hole, type_) = result
        type_
      })
  }

  use return <- result.try(return_type)
  let updated_environment =
    environment
    |> types.add_or_update_def_in_env(
      function.name,
      to_callable_type_with_original(param_state, return, function),
    )

  case function.publicity {
    glance.Private -> Ok(updated_environment)
    glance.Public ->
      Ok(types.publish_def_in_env(updated_environment, function.name))
  }
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
      update_function_signature(environment, function)
      |> list.Continue
  }
}

/// Used when checking the function signature.
/// Ensures that the types in the signature exist in our environment and maps them
/// to glimpse Types. Unannotated parameters are given a placeholder type that
/// will be replaced with the inferred type once the body has been checked.
pub fn fold_parameter_into_callable() -> fn(
  CallableStateResult,
  glance.FunctionParameter,
) -> CallableStateFold {
  fn(state, param) { fold_parameter_into_callable_inner(state, param) }
}

fn fold_parameter_into_callable_inner(
  state: CallableStateResult,
  param: glance.FunctionParameter,
) -> CallableStateFold {
  case state {
    Error(error) -> list.Stop(Error(error))
    Ok(CallableState(
      environment,
      reversed_by_position,
      labels,
      generic_var_counter,
      function_name,
    )) ->
      case param {
        glance.FunctionParameter(type_: option.None, label: option.None, ..) ->
          case dict.size(labels) == 0 {
            False -> list.Stop(Error(error.UnlabelledArgumentAfterLabelled))
            True ->
              list.Continue(
                Ok(CallableState(
                  environment,
                  [
                    types.GenericTypeVariable(
                      "t_"
                      <> function_name
                      <> "_"
                      <> int.to_string(generic_var_counter),
                    ),
                    ..reversed_by_position
                  ],
                  labels,
                  generic_var_counter + 1,
                  function_name,
                )),
              )
          }
        glance.FunctionParameter(
          type_: option.None,
          label: option.Some(label),
          ..,
        ) ->
          case dict.has_key(labels, label) {
            True -> list.Stop(Error(error.DuplicateArgumentName(label)))
            False ->
              list.Continue(
                Ok(CallableState(
                  environment,
                  [
                    types.GenericTypeVariable(
                      "t_"
                      <> function_name
                      <> "_"
                      <> int.to_string(generic_var_counter),
                    ),
                    ..reversed_by_position
                  ],
                  dict.insert(
                    labels,
                    label,
                    reversed_by_position |> list.length,
                  ),
                  generic_var_counter + 1,
                  function_name,
                )),
              )
          }

        glance.FunctionParameter(
          label: label,
          type_: option.Some(glance_type),
          ..,
        ) ->
          case
            types.type_with_holes(environment, generic_var_counter, glance_type)
          {
            Error(error) -> list.Stop(Error(error))
            Ok(#(next_hole, glimpse_type)) ->
              case label {
                option.None ->
                  list.Continue(
                    Ok(CallableState(
                      environment,
                      [glimpse_type, ..reversed_by_position],
                      labels,
                      next_hole,
                      function_name,
                    )),
                  )
                option.Some(label) ->
                  case dict.has_key(labels, label) {
                    True -> list.Stop(Error(error.DuplicateArgumentName(label)))
                    False ->
                      list.Continue(
                        Ok(CallableState(
                          environment,
                          [glimpse_type, ..reversed_by_position],
                          dict.insert(
                            labels,
                            label,
                            reversed_by_position |> list.length,
                          ),
                          next_hole,
                          function_name,
                        )),
                      )
                  }
              }
          }
      }
  }
}

/// Used when typechceking the function *body*. Adds all parameters to the environment
/// to be used as a local scope.
/// Unannotated parameters are given fresh inference variables, which are resolved
/// after the body has been checked.
pub type FunctionParamState {
  FunctionParamState(
    store: TypeStore,
    environment: Environment,
    publicity: glance.Publicity,
    /// (parameter index, fresh var type) for each parameter whose type was inferred
    inferred: List(#(Int, Type)),
    /// Maps annotation type-variable names to the fresh inference variable they
    /// were converted to. Kept across all parameters so the same name in two
    /// parameters refers to the same variable, letting inference tie annotated
    /// parameters to the return type.
    generic_vars: dict.Dict(String, Type),
    /// The function whose body is being checked, used to tie unannotated
    /// parameter variables to the function's signature variables.
    function_name: String,
  )
}

pub type FunctionParamStateResult =
  error.TypeCheckResult(FunctionParamState)

pub type FunctionParamStateFold =
  error.TypeCheckFold(FunctionParamState)

pub fn fold_function_parameter_into_env(
  state: FunctionParamStateResult,
  index: Int,
  param: glance.FunctionParameter,
) -> FunctionParamStateFold {
  case state {
    Error(_err) -> list.Stop(state)
    Ok(FunctionParamState(
      store,
      environment,
      publicity,
      inferred,
      generic_vars,
      function_name,
    )) ->
      case param {
        glance.FunctionParameter(type_: option.None, name: name, ..) -> {
          // The parameter is a fresh inference variable, tagged with the name
          // of the signature's generic variable so cross-function constraints
          // can be traced during the first pass.
          let #(store, type_) =
            types.fresh_var_with_source(
              store,
              signature_parameter_name(environment, function_name, index),
            )
          let environment = case name {
            glance.Named(n) ->
              types.add_or_update_def_in_env(environment, n, type_)
            glance.Discarded(_) -> environment
          }
          list.Continue(
            Ok(FunctionParamState(
              store,
              environment,
              publicity,
              [#(index, type_), ..inferred],
              generic_vars,
              function_name,
            )),
          )
        }

        glance.FunctionParameter(
          name: glance.Named(name),
          type_: option.Some(glance_type),
          ..,
        ) ->
          case types.type_with_store(environment, store, glance_type) {
            Error(error) -> list.Stop(Error(error))
            Ok(#(store, check_type)) -> {
              let #(store, generic_vars, converted) =
                freshen_generics(store, generic_vars, check_type)
              list.Continue(
                Ok(FunctionParamState(
                  store,
                  types.add_or_update_def_in_env(environment, name, converted),
                  publicity,
                  [#(index, converted), ..inferred],
                  generic_vars,
                  function_name,
                )),
              )
            }
          }

        glance.FunctionParameter(
          name: glance.Discarded(_),
          type_: option.Some(_),
          ..,
        ) ->
          list.Continue(
            Ok(FunctionParamState(
              store,
              environment,
              publicity,
              inferred,
              generic_vars,
              function_name,
            )),
          )
      }
  }
}

/// Replace any `GenericTypeVariable` in a type with a fresh inference variable,
/// reusing the same fresh variable for the same generic name. This keeps the
/// type variables introduced by a function's annotations shared across all of
/// the function's parameters, so inference can tie them to the return type.
/// Replace every declared type parameter in an annotation with its rigid
/// variable, sharing the same variable across all occurrences of the same name
/// (so `fn(x: a, y: a)` unifies the two `a`s). Used for function parameters and
/// function-literal parameters.
pub fn freshen_generics(
  store: TypeStore,
  generic_vars: dict.Dict(String, Type),
  type_: Type,
) -> #(TypeStore, dict.Dict(String, Type), Type) {
  case type_ {
    types.GenericTypeVariable(name) ->
      case dict.get(generic_vars, name) {
        Ok(existing) -> #(store, generic_vars, existing)
        Error(_) -> {
          // A declared type parameter becomes a fresh variable *linked* to the
          // named generic it stands for. Inside the function body it is a rigid
          // type variable: unification resolves it to `a` and rejects binding
          // it to a concrete type or to a different type parameter, exactly as
          // the real compiler does for `fn f(x: a) { x && True }`. The link is
          // what lets generalization and error messages still show `a`, and it
          // keeps type parameter names locally scoped (no cross-function
          // collisions, since rigidity is tracked per variable, not per name).
          let #(store, fresh) =
            types.fresh_var_with_source(store, "rigid:" <> name)
          let store =
            types.link_var_to(store, fresh, types.GenericTypeVariable(name))
          #(store, dict.insert(generic_vars, name, fresh), fresh)
        }
      }
    types.CustomType(module, name, parameters, inferred_variant) -> {
      let #(store, generic_vars, parameters) =
        list.fold(parameters, #(store, generic_vars, []), fn(state, parameter) {
          let #(store, generic_vars, acc) = state
          let #(store, generic_vars, parameter) =
            freshen_generics(store, generic_vars, parameter)
          #(store, generic_vars, [parameter, ..acc])
        })
      #(
        store,
        generic_vars,
        types.CustomType(
          module,
          name,
          list.reverse(parameters),
          inferred_variant,
        ),
      )
    }
    types.TupleType(elements) -> {
      let #(store, generic_vars, elements) =
        list.fold(elements, #(store, generic_vars, []), fn(state, element) {
          let #(store, generic_vars, acc) = state
          let #(store, generic_vars, element) =
            freshen_generics(store, generic_vars, element)
          #(store, generic_vars, [element, ..acc])
        })
      #(store, generic_vars, types.TupleType(list.reverse(elements)))
    }
    types.CallableType(parameters, labels, return) -> {
      let #(store, generic_vars, parameters) =
        list.fold(parameters, #(store, generic_vars, []), fn(state, parameter) {
          let #(store, generic_vars, acc) = state
          let #(store, generic_vars, parameter) =
            freshen_generics(store, generic_vars, parameter)
          #(store, generic_vars, [parameter, ..acc])
        })
      let #(store, generic_vars, return) =
        freshen_generics(store, generic_vars, return)
      #(
        store,
        generic_vars,
        types.CallableType(list.reverse(parameters), labels, return),
      )
    }
    _ -> #(store, generic_vars, type_)
  }
}

/// Ensure variant constructors are added as function types to the environment's
/// definition.
pub fn fold_variant_constructor_into_env(
  state: EnvStateResult(glance.CustomType),
  variant: glance.Variant,
  variant_index: Int,
) -> EnvStateResult(glance.CustomType) {
  case state {
    Error(error) -> Error(error)
    Ok(types.EnvState(environment, glance_custom_type)) -> {
      use callable_state <- result.try(
        variant.fields
        |> list.fold_until(
          Ok(empty_state(environment, glance_custom_type.name)),
          fold_variant_field_into_callable,
        ),
      )

      // Build the constructor's return type through `type_` so that built-in
      // generic types (List, Result, Option) use their dedicated
      // representations, matching how annotations of the same name resolve.
      let return_glance_type =
        glance.NamedType(
          glance.Span(-1, -1),
          glance_custom_type.name,
          option.None,
          list.map(glance_custom_type.parameters, fn(parameter) {
            glance.VariableType(glance.Span(-1, -1), parameter)
          }),
        )
      use return_type <- result.try(types.type_(environment, return_glance_type))
      // Remember which variant this constructor builds so that field access
      // on a value known (via pattern matching) to be this variant resolves
      // the field's type from the correct constructor.
      let return_type =
        types.set_custom_type_variant(return_type, variant_index)
      let constructor_type = case callable_state.reversed_by_position {
        // Zero-argument constructors are values of the custom type itself,
        // not functions, so store them as their plain return type. This
        // keeps them distinguishable from zero-argument functions.
        [] -> return_type
        _ ->
          to_callable_type_with_original(
            callable_state,
            return_type,
            dummy_function(),
          )
      }

      let environment =
        environment
        |> types.add_or_update_def_in_env(variant.name, constructor_type)

      case glance_custom_type.publicity {
        glance.Private -> Ok(types.EnvState(environment, glance_custom_type))
        glance.Public ->
          Ok(types.EnvState(
            types.publish_def_in_env(environment, variant.name),
            glance_custom_type,
          ))
      }
    }
  }
}

/// A sentinel function used as the `original_function` for variant constructor
/// callables. The field is never read, so a placeholder is sufficient.
pub fn dummy_function() -> glance.Function {
  glance.Function(glance.Span(-1, -1), "", glance.Private, [], option.None, [])
}

fn fold_variant_field_into_callable(
  state: CallableStateResult,
  field: glance.VariantField,
) -> CallableStateFold {
  case state {
    Error(error) -> list.Stop(Error(error))
    Ok(CallableState(
      environment,
      reversed_by_position,
      labels,
      generic_var_counter,
      function_name,
    )) ->
      {
        case field {
          glance.LabelledVariantField(item: glance_type, label: label) -> {
            use glimpse_type <- result.try(types.type_(environment, glance_type))
            Ok(CallableState(
              environment,
              [glimpse_type, ..reversed_by_position],
              dict.insert(labels, label, reversed_by_position |> list.length),
              generic_var_counter,
              function_name,
            ))
          }

          glance.UnlabelledVariantField(item: glance_type) -> {
            use glimpse_type <- result.try(types.type_(environment, glance_type))
            Ok(CallableState(
              environment,
              [glimpse_type, ..reversed_by_position],
              labels,
              generic_var_counter,
              function_name,
            ))
          }
        }
      }
      |> list.Continue
  }
}

/// The name of the `index`-th parameter of `function_name`'s signature. For
/// unannotated parameters this is the signature's generic variable name, used
/// to tag the body's inference variable so cross-function constraints can be
/// traced. Falls back to the deterministic name when the signature is
/// unavailable.
fn signature_parameter_name(
  environment: Environment,
  function_name: String,
  index: Int,
) -> String {
  let fallback = "t_" <> function_name <> "_" <> int.to_string(index)
  case signature_parameter_type(environment, function_name, index) {
    types.GenericTypeVariable(name) -> name
    _ -> fallback
  }
}

fn signature_parameter_type(
  environment: Environment,
  function_name: String,
  index: Int,
) -> Type {
  let fallback =
    types.GenericTypeVariable(
      "t_" <> function_name <> "_" <> int.to_string(index),
    )
  case dict.get(environment.definitions, function_name) {
    Ok(types.GenericCallableType(parameters, _, _, _)) ->
      parameter_at_index(parameters, index, fallback)
    Ok(types.CallableType(parameters, _, _)) ->
      parameter_at_index(parameters, index, fallback)
    _ -> fallback
  }
}

fn parameter_at_index(
  parameters: List(Type),
  index: Int,
  fallback: Type,
) -> Type {
  case parameters {
    [] -> fallback
    [head, ..rest] ->
      case index {
        0 -> head
        _ -> parameter_at_index(rest, index - 1, fallback)
      }
  }
}
