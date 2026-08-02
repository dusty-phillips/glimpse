import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
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

type OrderedFoldState {
  OrderedFoldState(
    reversed_ordered: List(Type),
    positional_remaining: List(Type),
  )
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
      fold_parameter_into_callable(function.publicity),
    ),
  )

  let return_type = case function.return {
    option.None -> {
      // If this is a private function with unannotated params (detected by generic vars in params),
      // use the `todo` wildcard for return. It unifies with anything, so calls to this
      // function (including recursive calls) can resolve their argument types during the
      // signature phase. It is replaced with the real return type once the body is checked.
      case
        has_generic_types(param_state.reversed_by_position)
        && function.publicity == glance.Private
      {
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
/// to glimpse Types. Unannotated parameters are permitted for private functions;
/// they are given a placeholder type that will be replaced with the inferred type
/// once the body has been checked.
pub fn fold_parameter_into_callable(
  publicity: glance.Publicity,
) -> fn(CallableStateResult, glance.FunctionParameter) -> CallableStateFold {
  fn(state, param) {
    fold_parameter_into_callable_inner(state, publicity, param)
  }
}

fn fold_parameter_into_callable_inner(
  state: CallableStateResult,
  publicity: glance.Publicity,
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
        glance.FunctionParameter(type_: option.None, name: name, ..) ->
          case publicity {
            glance.Public ->
              list.Stop(
                Error(error.MissingParameterAnnotation(parameter_name(name))),
              )
            glance.Private -> {
              let generic_name = "t" <> int.to_string(generic_var_counter)
              list.Continue(
                Ok(CallableState(
                  environment,
                  [
                    types.GenericTypeVariable(generic_name),
                    ..reversed_by_position
                  ],
                  labels,
                  generic_var_counter + 1,
                )),
              )
            }
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

fn parameter_name(name: glance.AssignmentName) -> String {
  case name {
    glance.Named(n) -> n
    glance.Discarded(d) -> d
  }
}

/// Used when typechceking the function *body*. Adds all parameters to the environment
/// to be used as a local scope.
/// Unannotated parameters of private functions are given fresh inference variables,
/// which are resolved after the body has been checked. Public functions still
/// require explicit parameter annotations.
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
        glance.FunctionParameter(type_: option.None, name: name, ..) ->
          case publicity {
            glance.Public ->
              list.Stop(
                Error(error.MissingParameterAnnotation(parameter_name(name))),
              )
            glance.Private -> {
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

        let environment =
          environment
          |> types.add_or_update_def_in_env(
            variant.name,
            to_callable_type_with_original(
              callable_state,
              types.CustomType(
                environment.current_module,
                glance_custom_type.name,
                list.map(glance_custom_type.parameters, fn(parameter) {
                  types.GenericTypeVariable(parameter)
                }),
              ),
              dummy_function(),
            ),
          )

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

/// Confirm that a function called with `called_with` can safely call
/// a function with the provided target_argument_types and position_labels.
///
/// These probably came from a match on types.Callable
///
/// Returns an error if:
/// * arity of called_with doesn't match target_argument_types
/// * called_with includes labelled arguments that are not in target_argument_types
/// * the types after mapping labels to positions do not match
pub fn order_call_arguments(
  environment: Environment,
  called_with: List(glance.Field(Type)),
  target_argument_types: List(Type),
  position_labels: dict.Dict(String, Int),
) -> error.TypeCheckResult(List(Type)) {
  let #(positional_called_with, labelled_called_with) =
    split_fields_by_type(environment, called_with)

  use called_with_types_by_position <- result.try(labels_to_position_dict(
    labelled_called_with,
    position_labels,
  ))

  let target_argument_types_result =
    list.index_fold(
      called_with,
      Ok(OrderedFoldState([], positional_called_with)),
      fn(state, _, index) {
        case state, dict.get(called_with_types_by_position, index) {
          Error(error), _ -> Error(error)
          Ok(OrderedFoldState(reversed_ordered, positional)), Ok(type_) ->
            Ok(OrderedFoldState([type_, ..reversed_ordered], positional))
          Ok(OrderedFoldState(reversed_ordered, [head, ..rest])), Error(_) ->
            Ok(OrderedFoldState([head, ..reversed_ordered], rest))
          Ok(OrderedFoldState(reversed_ordered, [])), Error(_) ->
            Error(argument_error(
              environment,
              target_argument_types,
              reversed_ordered,
            ))
        }
      },
    )
    |> result.map(fn(state) { state.reversed_ordered |> list.reverse })

  use positioned_argument_types <- result.try(target_argument_types_result)

  case
    list.length(positioned_argument_types) == list.length(target_argument_types)
  {
    True -> Ok(positioned_argument_types)
    False ->
      Error(argument_error(
        environment,
        target_argument_types,
        positioned_argument_types,
      ))
  }
}

/// Splits fields into positional and labelled types. Shorthand fields resolve
/// their variable from the environment, falling back to a generic type variable
/// when the variable isn't found (the error surfaces later during checking).
fn split_fields_by_type(
  environment: Environment,
  fields: List(glance.Field(Type)),
) -> #(List(Type), dict.Dict(String, Type)) {
  let #(reversed_positional, labelled) =
    list.fold(fields, #([], dict.new()), fn(state, field) {
      let #(reversed_positional, labelled) = state
      case field {
        glance.UnlabelledField(type_) -> #(
          [type_, ..reversed_positional],
          labelled,
        )
        glance.LabelledField(label, type_) -> #(
          reversed_positional,
          dict.insert(labelled, label, type_),
        )
        glance.ShorthandField(label) -> {
          let type_ =
            types.lookup_variable_type(environment, label)
            |> result.unwrap(types.GenericTypeVariable(label))
          #(reversed_positional, dict.insert(labelled, label, type_))
        }
      }
    })

  #(list.reverse(reversed_positional), labelled)
}

/// Given the dict of labeled args and their associated types
/// and a dict of what positions labels are expected to go at,
/// construct a dict mapping positions to types
///
/// Error if a label in the call site is not used in the destination
fn labels_to_position_dict(
  called_with_labels: dict.Dict(String, Type),
  target_label_positions: dict.Dict(String, Int),
) -> error.TypeCheckResult(dict.Dict(Int, Type)) {
  called_with_labels
  |> dict.to_list
  |> list.map(fn(tuple) {
    let #(label, type_) = tuple
    dict.get(target_label_positions, label)
    |> result.map(fn(position) { #(position, type_) })
    |> result.map_error(fn(_) {
      error.InvalidArgumentLabel(
        "(" <> target_label_positions |> dict.keys() |> string.join(", ") <> ")",
        label,
      )
    })
  })
  |> result.all
  |> result.map(dict.from_list)
}

fn argument_error(
  environment: Environment,
  expected: List(Type),
  actual: List(Type),
) -> error.TypeCheckError {
  error.InvalidArguments(
    "(" <> types.list_to_string(expected, environment) <> ")",
    "(" <> types.list_to_string(actual, environment) <> ")",
  )
}
