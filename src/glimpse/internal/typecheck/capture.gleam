import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import glimpse/error
import glimpse/internal/typecheck/functions
import glimpse/internal/typecheck/types.{
  type Environment, type Type, type TypeStore,
}

pub type CaptureState {
  CaptureState(
    claimed: set.Set(Int),
    /// (position, argument type) pairs, kept in reverse order
    consumed: List(#(Int, Type)),
    /// Next candidate position for an unlabelled argument
    counter: Int,
  )
}

/// Typecheck a function capture (`f(1, _)`). The target is instantiated, the
/// provided arguments are unified against the parameter positions they consume,
/// and the remaining positions become the parameters of the partial callable.
pub fn fn_capture(
  environment: Environment,
  store: TypeStore,
  parameters: List(Type),
  labels: dict.Dict(String, Int),
  return: Type,
  hole_label: option.Option(String),
  typed_before: List(glance.Field(Type)),
  typed_after: List(glance.Field(Type)),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  let parameter_count = list.length(parameters)
  let all_fields = list.append(typed_before, typed_after)
  let provided_types = list.map(all_fields, field_type)
  let too_many = too_many_arguments(environment, parameters, provided_types)

  use before_state <- result.try(
    list.try_fold(
      typed_before,
      CaptureState(set.new(), [], 0),
      fn(state, field) {
        capture_field(labels, parameter_count, too_many, state, field)
      },
    ),
  )

  let hole_position = case hole_label {
    option.Some(label) ->
      dict.get(labels, label)
      |> result.map_error(fn(_) {
        error.InvalidArgumentLabel(
          "(" <> labels |> dict.keys() |> string.join(", ") <> ")",
          label,
        )
      })
    option.None ->
      Ok(next_free_slot(before_state.claimed, before_state.counter))
  }

  use hole_position <- result.try(hole_position)

  case hole_position >= parameter_count {
    True -> Error(too_many)
    False -> {
      let with_hole =
        CaptureState(
          claimed: set.insert(before_state.claimed, hole_position),
          consumed: before_state.consumed,
          counter: before_state.counter,
        )

      use after_state <- result.try(
        list.try_fold(typed_after, with_hole, fn(state, field) {
          capture_field(labels, parameter_count, too_many, state, field)
        }),
      )

      let consumed = list.reverse(after_state.consumed)

      use store <- result.try(
        list.try_fold(consumed, store, fn(store, pair) {
          let #(position, arg_type) = pair
          let assert Ok(param_type) =
            list.drop(parameters, up_to: position) |> list.first
          types.unify(store, environment, arg_type, param_type)
        }),
      )

      let consumed_positions =
        list.fold(consumed, set.new(), fn(positions, pair) {
          let #(position, _) = pair
          set.insert(positions, position)
        })

      let #(remaining_reversed, reindexed_labels) =
        list.index_map(parameters, fn(param, index) { #(param, index) })
        |> list.fold(#([], dict.new()), fn(state, pair) {
          let #(reversed_params, new_labels) = state
          let #(param, index) = pair
          case set.contains(consumed_positions, index) {
            True -> state
            False -> {
              let consumed_before =
                set.fold(consumed_positions, 0, fn(count, position) {
                  case position < index {
                    True -> count + 1
                    False -> count
                  }
                })
              let new_position = index - consumed_before
              let new_labels =
                dict.fold(labels, new_labels, fn(acc, label, label_position) {
                  case label_position == index {
                    True -> dict.insert(acc, label, new_position)
                    False -> acc
                  }
                })
              #([param, ..reversed_params], new_labels)
            }
          }
        })

      // Keep rigid type variables in the return (e.g. a signature type param
      // pinned by a supplied capture argument) so the capture stays pinned to
      // them; plain resolve would collapse them to their named generics, which
      // are freshened at the use site and lose the linkage.
      let #(_, resolved_return) = types.resolve_keep_rigid(store, return)
      let generalised =
        types.generalise(
          store,
          types.CallableType(
            list.reverse(remaining_reversed),
            reindexed_labels,
            resolved_return,
          ),
        )

      let capture_type = case generalised {
        types.CallableType(parameters, labels, return) ->
          case
            functions.has_generic_types(parameters)
            || functions.is_generic_type(return)
          {
            True ->
              types.GenericCallableType(
                parameters,
                labels,
                return,
                functions.dummy_function(),
              )
            False -> generalised
          }
        other -> other
      }

      Ok(#(store, capture_type))
    }
  }
}

/// Assign a single capture argument to the parameter position it consumes,
/// threading the walk state. The argument is appended to `consumed`; the
/// position is marked claimed so later arguments and the hole can't reuse it.
fn capture_field(
  labels: dict.Dict(String, Int),
  parameter_count: Int,
  too_many: error.TypeCheckError,
  state: CaptureState,
  field: glance.Field(Type),
) -> Result(CaptureState, error.TypeCheckError) {
  case field {
    glance.LabelledField(label, _, type_) ->
      dict.get(labels, label)
      |> result.map_error(fn(_) {
        error.InvalidArgumentLabel(
          "(" <> labels |> dict.keys() |> string.join(", ") <> ")",
          label,
        )
      })
      |> result.try(fn(position) {
        case
          position >= parameter_count || set.contains(state.claimed, position)
        {
          True -> Error(too_many)
          False ->
            Ok(CaptureState(
              set.insert(state.claimed, position),
              [#(position, type_), ..state.consumed],
              state.counter,
            ))
        }
      })
    glance.UnlabelledField(type_) -> {
      let position = next_free_slot(state.claimed, state.counter)
      case position >= parameter_count {
        True -> Error(too_many)
        False ->
          Ok(CaptureState(
            set.insert(state.claimed, position),
            [#(position, type_), ..state.consumed],
            position + 1,
          ))
      }
    }
    glance.ShorthandField(label, _) -> Error(error.InvalidName(label))
  }
}

/// Smallest position at or after `counter` not already claimed.
pub fn next_free_slot(claimed: set.Set(Int), counter: Int) -> Int {
  case set.contains(claimed, counter) {
    True -> next_free_slot(claimed, counter + 1)
    False -> counter
  }
}

pub fn field_type(field: glance.Field(Type)) -> Type {
  case field {
    glance.LabelledField(_, _, type_) -> type_
    glance.UnlabelledField(type_) -> type_
    glance.ShorthandField(_, _) ->
      panic as "Shorthand fields are resolved before field_type"
  }
}

pub fn too_many_arguments(
  environment: Environment,
  parameters: List(Type),
  provided: List(Type),
) -> error.TypeCheckError {
  error.InvalidArguments(
    "(" <> types.list_to_string(parameters, environment) <> ")",
    "(" <> types.list_to_string(provided, environment) <> ")",
  )
}
