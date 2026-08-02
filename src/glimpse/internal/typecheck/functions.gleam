import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import glimpse/error
import glimpse/internal/typecheck/types.{
  type EnvStateFold, type EnvStateResult, type Environment, type EnvironmentFold,
  type EnvironmentResult, type Type, type TypeStore,
}

pub type CallableState {
  CallableState(
    environment: Environment,
    reversed_by_position: List(Type),
    labels: dict.Dict(String, Int),
    /// Counter for generating unique generic type variable names for unannotated params
    generic_var_counter: Int,
  )
}

pub type CallableStateResult =
  error.TypeCheckResult(CallableState)

pub type CallableStateFold =
  error.TypeCheckFold(CallableState)

pub fn empty_state(environment: Environment) -> CallableState {
  CallableState(environment, [], dict.new(), 0)
}

pub fn has_generic_types(types: List(Type)) -> Bool {
  list.any(types, is_generic_type)
}

pub fn is_generic_type(type_: Type) -> Bool {
  case type_ {
    types.GenericTypeVariable(_) -> True
    types.CustomType(_, _, parameters) -> list.any(parameters, is_generic_type)
    types.ListType(element) -> is_generic_type(element)
    types.TupleType(elements) -> list.any(elements, is_generic_type)
    types.ResultType(ok, error) -> is_generic_type(ok) || is_generic_type(error)
    types.OptionType(inner) -> is_generic_type(inner)
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
      Ok(empty_state(environment)),
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
      types.type_(environment, glance_return_type)
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
    )) ->
      case param {
        glance.FunctionParameter(type_: option.None, ..) -> {
          let generic_name = "t" <> int.to_string(generic_var_counter)
          list.Continue(
            Ok(CallableState(
              environment,
              [types.GenericTypeVariable(generic_name), ..reversed_by_position],
              labels,
              generic_var_counter + 1,
            )),
          )
        }

        glance.FunctionParameter(
          label: label,
          type_: option.Some(glance_type),
          ..,
        ) ->
          case types.type_(environment, glance_type) {
            Error(error) -> list.Stop(Error(error))
            Ok(glimpse_type) -> {
              let labels = case label {
                option.None -> labels
                option.Some(label) ->
                  dict.insert(
                    labels,
                    label,
                    reversed_by_position |> list.length,
                  )
              }
              list.Continue(
                Ok(CallableState(
                  environment,
                  [glimpse_type, ..reversed_by_position],
                  labels,
                  generic_var_counter,
                )),
              )
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
    Ok(FunctionParamState(store, environment, publicity, inferred)) ->
      case param {
        glance.FunctionParameter(type_: option.None, name: name, ..) -> {
          let #(store, type_) = types.fresh_var(store)
          let environment = case name {
            glance.Named(n) ->
              types.add_or_update_def_in_env(environment, n, type_)
            glance.Discarded(_) -> environment
          }
          list.Continue(
            Ok(
              FunctionParamState(store, environment, publicity, [
                #(index, type_),
                ..inferred
              ]),
            ),
          )
        }

        glance.FunctionParameter(
          name: glance.Named(name),
          type_: option.Some(glance_type),
          ..,
        ) ->
          case types.type_(environment, glance_type) {
            Error(error) -> list.Stop(Error(error))
            Ok(check_type) ->
              list.Continue(
                Ok(FunctionParamState(
                  store,
                  types.add_or_update_def_in_env(environment, name, check_type),
                  publicity,
                  inferred,
                )),
              )
          }

        glance.FunctionParameter(
          name: glance.Discarded(_),
          type_: option.Some(_),
          ..,
        ) ->
          list.Continue(
            Ok(FunctionParamState(store, environment, publicity, inferred)),
          )
      }
  }
}

/// Ensure variant constructors are added as function types to the environment's
/// definition.
pub fn fold_variant_constructors_into_env(
  state: EnvStateResult(glance.CustomType),
  variant: glance.Variant,
) -> EnvStateFold(glance.CustomType) {
  case state {
    Error(error) -> list.Stop(Error(error))
    Ok(types.EnvState(environment, glance_custom_type)) ->
      {
        use callable_state <- result.try(
          variant.fields
          |> list.fold_until(
            Ok(empty_state(environment)),
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
        use return_type <- result.try(types.type_(
          environment,
          return_glance_type,
        ))
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
      |> list.Continue
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
            ))
          }

          glance.UnlabelledVariantField(item: glance_type) -> {
            use glimpse_type <- result.try(types.type_(environment, glance_type))
            Ok(CallableState(
              environment,
              [glimpse_type, ..reversed_by_position],
              labels,
              generic_var_counter,
            ))
          }
        }
      }
      |> list.Continue
  }
}
