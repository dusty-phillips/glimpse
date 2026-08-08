import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import glimpse/error
import glimpse/internal/typecheck/exhaustive
import glimpse/internal/typecheck/types.{
  type Environment, type Type, type TypeStore,
}

/// Extract the parameters, labels, and return type of a call target, so a call
/// can be checked against them. A target that is a bare unbound variable (an
/// unannotated higher-order parameter) is constrained to a fresh callable
/// taking the given number of arguments.
pub fn callable_parts(
  environment: Environment,
  store: TypeStore,
  target: types.Type,
  argument_count: Int,
) -> error.TypeCheckResult(
  #(TypeStore, List(types.Type), dict.Dict(String, Int), types.Type),
) {
  case target {
    types.CallableType(_, _, _) | types.GenericCallableType(_, _, _, _) -> {
      let #(store, parameters, labels, return) =
        types.instantiate_callable(store, target)
      Ok(#(store, parameters, labels, return))
    }
    types.Var(_) | types.InferredReturn -> {
      let #(store, parameters) = types.fresh_vars(store, argument_count)
      let #(store, return) = types.fresh_var(store)
      let callable = types.CallableType(parameters, dict.new(), return)
      types.unify(store, environment, target, callable)
      |> result.map(fn(store) { #(store, parameters, dict.new(), return) })
    }
    _ -> Error(error.NotCallable(types.to_string(environment, target)))
  }
}

/// Record how a same-module callee's generic parameters are constrained by the
/// arguments at this call site, so a cycle of embedding constraints across
/// functions is reported as a recursive type.
pub fn record_generic_constraints(
  environment: Environment,
  store: TypeStore,
  callee: String,
  arguments: List(glance.Field(glance.Expression)),
) -> Result(TypeStore, error.TypeCheckError) {
  case dict.get(environment.scope.definitions, callee) {
    Ok(types.GenericCallableType(parameters, _, return_, _)) ->
      case is_placeholder_return(return_) {
        False -> Ok(store)
        True ->
          list.try_fold(
            list.zip(
              parameters,
              list.map(arguments, fn(field) {
                case field {
                  glance.UnlabelledField(expr) -> expr
                  glance.LabelledField(_, _, expr) -> expr
                  glance.ShorthandField(_, _) ->
                    glance.Int(glance.Span(-1, -1), "0")
                }
              }),
            ),
            store,
            fn(store, pair) {
              let #(parameter, argument) = pair
              case parameter {
                types.GenericTypeVariable(name) ->
                  types.record_generic_edge(
                    store,
                    name,
                    argument_named_vars(environment, store, argument),
                  )
                _ -> Ok(store)
              }
            },
          )
      }
    _ -> Ok(store)
  }
}

/// The named generic variables an argument expression can embed, from the
/// bindings its sub-expressions resolve to. Only names that appear directly
/// (variable lookups, constructor arguments, list/tuple elements) are counted;
/// the argument is not typechecked here.
pub fn argument_named_vars(
  environment: Environment,
  store: TypeStore,
  argument: glance.Expression,
) -> List(String) {
  case argument {
    glance.Variable(_, name) ->
      case dict.get(environment.scope.definitions, name) {
        Ok(type_) -> types.named_vars_including_sources(store, type_)
        Error(_) -> []
      }
    glance.List(_, elements, tail) ->
      list.append(
        elements
          |> list.map(fn(element) {
            argument_named_vars(environment, store, element)
          })
          |> list.flatten,
        case tail {
          option.Some(tail_expr) ->
            argument_named_vars(environment, store, tail_expr)
          option.None -> []
        },
      )
    glance.Tuple(_, elements) ->
      elements
      |> list.map(fn(element) {
        argument_named_vars(environment, store, element)
      })
      |> list.flatten
    glance.Call(_, _, fields) ->
      fields
      |> list.map(fn(field) {
        case field {
          glance.UnlabelledField(expr) ->
            argument_named_vars(environment, store, expr)
          glance.LabelledField(_, _, expr) ->
            argument_named_vars(environment, store, expr)
          glance.ShorthandField(_, _) -> []
        }
      })
      |> list.flatten
    glance.BitString(_, segments) ->
      segments
      |> list.map(fn(segment) {
        let #(value_expr, _options) = segment
        argument_named_vars(environment, store, value_expr)
      })
      |> list.flatten
    _ -> []
  }
}

pub fn placeholder_callee(environment: Environment, callee: String) -> Bool {
  case dict.get(environment.scope.definitions, callee) {
    Ok(types.GenericCallableType(_, _, return_, _)) ->
      is_placeholder_return(return_)
    _ -> False
  }
}

pub fn is_placeholder_return(type_: Type) -> Bool {
  case type_ {
    types.InferredReturn -> True
    types.TodoType -> True
    _ -> False
  }
}

/// Align argument fields to parameter positions by label (for labelled and
/// shorthand fields) and position (for unlabelled fields), returning the fields
/// in parameter order. Reports `InvalidArgumentLabel` for unknown labels.
/// Argument count equality must be established by the caller.
pub fn align_argument_fields(
  fields: List(glance.Field(glance.Expression)),
  position_labels: dict.Dict(String, Int),
  param_count: Int,
) -> error.TypeCheckResult(List(glance.Field(glance.Expression))) {
  // A positional argument may not follow a labelled one in source order.
  case positional_argument_after_labelled(fields) {
    True -> Error(error.PositionalArgumentAfterLabelled)
    False -> align_argument_fields_(fields, position_labels, param_count)
  }
}

pub fn align_argument_fields_(
  fields: List(glance.Field(glance.Expression)),
  position_labels: dict.Dict(String, Int),
  param_count: Int,
) -> error.TypeCheckResult(List(glance.Field(glance.Expression))) {
  let #(positional, labelled) =
    list.fold(fields, #([], dict.new()), fn(state, field) {
      let #(positional, labelled) = state
      case field {
        glance.UnlabelledField(_) -> #([field, ..positional], labelled)
        glance.LabelledField(label, _, _) -> #(
          positional,
          dict.insert(labelled, label, field),
        )
        glance.ShorthandField(label, _) -> #(
          positional,
          dict.insert(labelled, label, field),
        )
      }
    })
  let positional = list.reverse(positional)

  // Place labelled/shorthand fields at their labelled parameter position,
  // surfacing an `InvalidArgumentLabel` error for any label the callable does
  // not declare.
  use by_position <- result.try(
    list.try_fold(dict.to_list(labelled), dict.new(), fn(by_position, pair) {
      let #(label, field) = pair
      use position <- result.try(
        dict.get(position_labels, label)
        |> result.replace_error(error.InvalidArgumentLabel(
          "("
            <> position_labels
          |> dict.keys
          |> list.sort(string.compare)
          |> string.join(", ")
            <> ")",
          label,
        )),
      )
      Ok(dict.insert(by_position, position, field))
    }),
  )

  // Fill the remaining (unlabelled) parameter positions with positional
  // arguments, in source order. A label error already short-circuited above;
  // here a count mismatch means too few positional arguments, which the
  // caller's arity check should have ruled out, but guard defensively.
  let #(_, acc) =
    list.fold_until(
      exhaustive.range(0, param_count),
      #(positional, []),
      fn(state, position) {
        let #(remaining, acc) = state
        case dict.get(by_position, position) {
          Ok(field) -> list.Continue(#(remaining, [field, ..acc]))
          Error(_) ->
            case remaining {
              [] -> list.Stop(#([], acc))
              [field, ..rest] -> list.Continue(#(rest, [field, ..acc]))
            }
        }
      },
    )
  Ok(list.reverse(acc))
}

/// Whether a list of argument fields contains a positional argument that
/// appears after a labelled one, which the language forbids.
pub fn positional_argument_after_labelled(
  fields: List(glance.Field(glance.Expression)),
) -> Bool {
  let #(_seen_labelled, found) =
    list.fold(fields, #(False, False), fn(state, field) {
      let #(seen_labelled, found) = state
      case field {
        glance.LabelledField(_, _, _) | glance.ShorthandField(_, _) -> #(
          True,
          found,
        )
        glance.UnlabelledField(_) -> #(seen_labelled, found || seen_labelled)
      }
    })
  found
}
