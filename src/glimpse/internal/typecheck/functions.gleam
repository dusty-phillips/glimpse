import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import glimpse/error
import glimpse/internal/typecheck/types.{
  type EnvStateFold, type EnvStateResult, type Environment, type EnvironmentFold,
  type EnvironmentResult, type Type,
}

pub type CallableState {
  CallableState(
    environment: Environment,
    reversed_by_position: List(Type),
    labels: dict.Dict(String, Int),
  )
}

pub type CallableStateResult =
  error.TypeCheckResult(CallableState)

pub type CallableStateFold =
  error.TypeCheckFold(CallableState)

pub fn empty_state(environment: Environment) -> CallableState {
  CallableState(environment, [], dict.new())
}

fn has_generic_types(types: List(Type)) -> Bool {
  list.any(types, is_generic_type)
}

fn is_generic_type(type_: Type) -> Bool {
  case type_ {
    types.GenericTypeVariable(_) -> True
    _ -> False
  }
}

pub fn to_callable_type(state: CallableState, return_type: Type) -> Type {
  types.CallableType(
    state.reversed_by_position |> list.reverse,
    state.labels,
    return_type,
  )
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
      fold_parameter_into_callable,
    ),
  )

  let return_type = case function.return {
    option.None -> Ok(types.InferredReturn)
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
/// to glimpse Types.
pub fn fold_parameter_into_callable(
  state: CallableStateResult,
  param: glance.FunctionParameter,
) -> CallableStateFold {
  case state {
    Error(error) -> list.Stop(Error(error))
    Ok(CallableState(environment, reversed_by_position, labels)) -> {
      case param {
        glance.FunctionParameter(type_: option.None, ..) ->
          todo as "Not inferring function parameters yet (requires generics or Skolem vars)"

        glance.FunctionParameter(
          label: option.Some(label),
          type_: option.Some(glance_type),
          ..,
        ) -> {
          use glimpse_type <- result.try(types.type_(environment, glance_type))
          Ok(CallableState(
            environment,
            [glimpse_type, ..reversed_by_position],
            dict.insert(labels, label, reversed_by_position |> list.length),
          ))
        }

        glance.FunctionParameter(
          label: option.None,
          type_: option.Some(glance_type),
          ..,
        ) -> {
          use glimpse_type <- result.try(types.type_(environment, glance_type))
          Ok(CallableState(
            environment,
            [glimpse_type, ..reversed_by_position],
            labels,
          ))
        }
      }
      |> list.Continue
    }
  }
}

/// Used when typechceking the function *body*. Adds all parameters to the environment
/// to be used as a local scope.
pub fn fold_function_parameter_into_env(
  state: EnvironmentResult,
  param: glance.FunctionParameter,
) -> EnvironmentFold {
  case state {
    Error(_err) -> list.Stop(state)
    Ok(environment) ->
      {
        case param {
          glance.FunctionParameter(name: glance.Discarded(_), ..) ->
            Ok(environment)
          glance.FunctionParameter(type_: option.None, ..) ->
            todo as "Not inferring function parameters yet"
          glance.FunctionParameter(
            name: glance.Named(name),
            type_: option.Some(glance_type),
            ..,
          ) -> {
            use check_type <- result.try(types.type_(environment, glance_type))
            Ok(types.add_or_update_def_in_env(environment, name, check_type))
          }
        }
      }
      |> list.Continue
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
            to_callable_type(
              callable_state,
              types.CustomType(
                environment.current_module,
                glance_custom_type.name,
              ),
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

fn fold_variant_field_into_callable(
  state: CallableStateResult,
  field: glance.VariantField,
) -> CallableStateFold {
  case state {
    Error(error) -> list.Stop(Error(error))
    Ok(CallableState(environment, reversed_by_position, labels)) ->
      {
        case field {
          glance.LabelledVariantField(item: glance_type, label: label) -> {
            use glimpse_type <- result.try(types.type_(environment, glance_type))
            Ok(CallableState(
              environment,
              [glimpse_type, ..reversed_by_position],
              dict.insert(labels, label, reversed_by_position |> list.length),
            ))
          }

          glance.UnlabelledVariantField(item: glance_type) -> {
            use glimpse_type <- result.try(types.type_(environment, glance_type))
            Ok(CallableState(
              environment,
              [glimpse_type, ..reversed_by_position],
              labels,
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
    split_fields_by_type(called_with)

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

  case positioned_argument_types == target_argument_types {
    True -> Ok(positioned_argument_types)
    False ->
      Error(argument_error(
        environment,
        target_argument_types,
        positioned_argument_types,
      ))
  }
}

fn split_fields_by_type(
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
        glance.ShorthandField(_label) -> {
          // For shorthand syntax like `name:`, we need to look up the variable `name` in scope
          // This is syntactic sugar for `name: name`
          todo as "ShorthandField resolution requires environment context - not yet implemented"
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
