import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import glimpse/error
import glimpse/internal/typecheck/environment
import glimpse/internal/typecheck/types.{type Type}

pub type CallableState {
  CallableState(
    environment: environment.Environment,
    reversed_by_position: List(Type),
    labels: dict.Dict(String, Int),
  )
}

pub type CallableStateResult =
  error.TypeCheckResult(CallableState)

pub type CallableStateFold =
  error.TypeCheckFold(CallableState)

pub fn empty_state(environment: environment.Environment) -> CallableState {
  CallableState(environment, [], dict.new())
}

pub fn to_callable_type(state: CallableState, return_type: Type) -> Type {
  types.CallableType(
    state.reversed_by_position |> list.reverse,
    state.labels,
    return_type,
  )
}

type OrderedFoldState {
  OrderedFoldState(
    reversed_ordered: List(Type),
    positional_remaining: List(Type),
  )
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
            Error(argument_error(target_argument_types, reversed_ordered))
        }
      },
    )
    |> result.map(fn(state) { state.reversed_ordered |> list.reverse })

  use positioned_argument_types <- result.try(target_argument_types_result)

  case positioned_argument_types == target_argument_types {
    True -> Ok(positioned_argument_types)
    False ->
      Error(argument_error(target_argument_types, positioned_argument_types))
  }
}

fn split_fields_by_type(
  fields: List(glance.Field(Type)),
) -> #(List(Type), dict.Dict(String, Type)) {
  let #(reversed_positional, labelled) =
    list.fold(fields, #([], dict.new()), fn(state, field) {
      let #(reversed_positional, labelled) = state
      case field {
        glance.Field(option.None, type_) -> #(
          [type_, ..reversed_positional],
          labelled,
        )
        glance.Field(option.Some(label), type_) -> #(
          reversed_positional,
          dict.insert(labelled, label, type_),
        )
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
  expected: List(Type),
  actual: List(Type),
) -> error.TypeCheckError {
  error.InvalidArguments(
    "(" <> types.list_to_string(expected) <> ")",
    "(" <> types.list_to_string(actual) <> ")",
  )
}
