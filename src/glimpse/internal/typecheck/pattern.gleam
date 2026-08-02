import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import glimpse/error
import glimpse/internal/typecheck/types

/// Check that a pattern is compatible with the expected type, returning the
/// environment extended with any variable bindings the pattern introduces.
pub fn typecheck_pattern(
  environment: types.Environment,
  expected_type: types.Type,
  pattern: glance.Pattern,
) -> error.TypeCheckResult(types.Environment) {
  case pattern {
    glance.PatternVariable(_, name) ->
      bind_variable(environment, name, expected_type)

    glance.PatternDiscard(_, _) -> Ok(environment)

    glance.PatternInt(_, _) -> {
      case expected_type {
        types.IntType -> Ok(environment)
        _ ->
          Error(error.PatternMismatch(
            "int pattern",
            "Int",
            types.to_string(environment, expected_type),
          ))
      }
    }

    glance.PatternFloat(_, _) -> {
      case expected_type {
        types.FloatType -> Ok(environment)
        _ ->
          Error(error.PatternMismatch(
            "float pattern",
            "Float",
            types.to_string(environment, expected_type),
          ))
      }
    }

    glance.PatternString(_, _) -> {
      case expected_type {
        types.StringType -> Ok(environment)
        _ ->
          Error(error.PatternMismatch(
            "string pattern",
            "String",
            types.to_string(environment, expected_type),
          ))
      }
    }

    glance.PatternTuple(_, elements) -> {
      case expected_type {
        types.TupleType(tuple_elements) ->
          case list.length(tuple_elements) == list.length(elements) {
            True ->
              list.zip(elements, tuple_elements)
              |> list.try_fold(environment, fn(env, pair) {
                let #(element, expected) = pair
                typecheck_pattern(env, expected, element)
              })
            False -> tuple_mismatch(environment, expected_type)
          }
        _ -> tuple_mismatch(environment, expected_type)
      }
    }

    glance.PatternList(_, elements, tail) -> {
      case expected_type {
        types.ListType(element_type) -> {
          use environment <- result.try(fold_patterns(
            environment,
            element_type,
            elements,
          ))
          case tail {
            option.None -> Ok(environment)
            option.Some(tail_pattern) ->
              typecheck_pattern(
                environment,
                types.ListType(element_type),
                tail_pattern,
              )
          }
        }
        _ ->
          Error(error.PatternMismatch(
            "list pattern",
            "List",
            types.to_string(environment, expected_type),
          ))
      }
    }

    glance.PatternVariant(_, module, constructor, arguments, _with_spread) -> {
      use callable <- result.try(lookup_constructor(
        environment,
        module,
        constructor,
      ))
      case callable {
        types.CallableType(..) | types.GenericCallableType(..) -> {
          let #(store, parameters, position_labels, constructor_return) =
            types.instantiate_callable(types.new_type_store(), callable)
          use store <- result.try(types.unify(
            store,
            environment,
            expected_type,
            constructor_return,
          ))
          let resolved_parameters =
            list.map(parameters, fn(parameter) {
              let #(_store, resolved) = types.resolve(store, parameter)
              types.generalise(store, resolved)
            })
          check_variant_arguments(
            environment,
            arguments,
            resolved_parameters,
            position_labels,
          )
        }
        _ -> Error(error.NotCallable(types.to_string(environment, callable)))
      }
    }

    glance.PatternAssignment(_, attern, name) -> {
      use environment <- result.try(bind_variable(
        environment,
        name,
        expected_type,
      ))
      typecheck_pattern(environment, expected_type, attern)
    }

    glance.PatternConcatenate(_, _prefix, prefix_name, rest_name) -> {
      case expected_type {
        types.StringType -> {
          use environment <- result.try(bind_assignment_name(
            environment,
            prefix_name,
          ))
          case rest_name {
            glance.Named(name) ->
              bind_variable(environment, name, types.StringType)
            glance.Discarded(_) -> Ok(environment)
          }
        }
        _ ->
          Error(error.PatternMismatch(
            "string concatenation pattern",
            "String",
            types.to_string(environment, expected_type),
          ))
      }
    }

    glance.PatternBitString(_, segments) -> {
      case expected_type {
        types.BitArrayType -> {
          list.try_fold(segments, environment, fn(env, segment) {
            let #(pattern, options) = segment
            typecheck_pattern(env, bit_string_segment_type(options), pattern)
          })
        }
        _ ->
          Error(error.PatternMismatch(
            "bit array pattern",
            "BitArray",
            types.to_string(environment, expected_type),
          ))
      }
    }
  }
}

fn bind_variable(
  environment: types.Environment,
  name: String,
  type_: types.Type,
) -> error.TypeCheckResult(types.Environment) {
  case dict.get(environment.definitions, name) {
    Ok(existing) if existing == type_ -> Ok(environment)
    Ok(existing) ->
      Error(error.InvalidType(
        types.to_string(environment, existing),
        types.to_string(environment, type_),
        "cannot rebind variable with different type",
      ))
    Error(_) -> Ok(types.add_or_update_def_in_env(environment, name, type_))
  }
}

fn fold_patterns(
  environment: types.Environment,
  expected_type: types.Type,
  patterns: List(glance.Pattern),
) -> error.TypeCheckResult(types.Environment) {
  list.try_fold(patterns, environment, fn(env, pattern) {
    typecheck_pattern(env, expected_type, pattern)
  })
}

fn tuple_mismatch(
  environment: types.Environment,
  expected_type: types.Type,
) -> error.TypeCheckResult(types.Environment) {
  Error(error.PatternMismatch(
    "tuple pattern",
    types.to_string(environment, expected_type),
    "tuple",
  ))
}

fn lookup_constructor(
  environment: types.Environment,
  module: option.Option(String),
  constructor: String,
) -> error.TypeCheckResult(types.Type) {
  case module {
    option.None -> types.lookup_variable_type(environment, constructor)
    option.Some(module_name) -> {
      case dict.get(environment.definitions, module_name) {
        Ok(types.NamespaceType(definitions, _custom_types)) ->
          dict.get(definitions, constructor)
          |> result.replace_error(error.InvalidName(constructor))
        _ -> Error(error.InvalidName(constructor))
      }
    }
  }
}

/// Check that a pattern matching a constructor of a custom type is being used
/// against a value of that same custom type.
fn check_variant_arguments(
  environment: types.Environment,
  arguments: List(glance.Field(glance.Pattern)),
  parameters: List(types.Type),
  position_labels: dict.Dict(String, Int),
) -> error.TypeCheckResult(types.Environment) {
  list.try_fold(arguments, #(environment, 0), fn(state, field) {
    let #(env, positional_count) = state
    use expected <- result.try(variant_field_expected_type(
      env,
      parameters,
      position_labels,
      positional_count,
      field,
    ))
    case field {
      glance.UnlabelledField(pattern) -> {
        use env <- result.try(typecheck_pattern(env, expected, pattern))
        Ok(#(env, positional_count + 1))
      }
      glance.LabelledField(_label, pattern) -> {
        use env <- result.try(typecheck_pattern(env, expected, pattern))
        Ok(#(env, positional_count))
      }
      glance.ShorthandField(_label) -> Ok(#(env, positional_count))
    }
  })
  |> result.map(fn(state) {
    let #(environment, _positional_count) = state
    environment
  })
}

fn variant_field_expected_type(
  environment: types.Environment,
  parameters: List(types.Type),
  position_labels: dict.Dict(String, Int),
  positional_count: Int,
  field: glance.Field(glance.Pattern),
) -> error.TypeCheckResult(types.Type) {
  case field {
    glance.LabelledField(label, _) | glance.ShorthandField(label) -> {
      case dict.get(position_labels, label) {
        Ok(position) -> parameter_at(environment, parameters, position)
        Error(_) -> unknown_label_error(position_labels, label)
      }
    }
    glance.UnlabelledField(_) ->
      parameter_at(environment, parameters, positional_count)
  }
}

fn parameter_at(
  environment: types.Environment,
  parameters: List(types.Type),
  position: Int,
) -> error.TypeCheckResult(types.Type) {
  parameters
  |> list.drop(up_to: position)
  |> list.first
  |> result.replace_error(error.InvalidArguments(
    "(" <> types.list_to_string(parameters, environment) <> ")",
    "too many arguments",
  ))
}

fn unknown_label_error(
  position_labels: dict.Dict(String, Int),
  label: String,
) -> error.TypeCheckResult(types.Type) {
  let labels = dict.keys(position_labels) |> string.join(", ")
  Error(error.InvalidArgumentLabel("(" <> labels <> ")", label))
}

fn bind_assignment_name(
  environment: types.Environment,
  name: option.Option(glance.AssignmentName),
) -> error.TypeCheckResult(types.Environment) {
  case name {
    option.None -> Ok(environment)
    option.Some(glance.Named(bound_name)) ->
      bind_variable(environment, bound_name, types.StringType)
    option.Some(glance.Discarded(_)) -> Ok(environment)
  }
}

fn bit_string_segment_type(
  options: List(glance.BitStringSegmentOption(glance.Pattern)),
) -> types.Type {
  case list.any(options, is_string_option) {
    True -> types.StringType
    False -> types.IntType
  }
}

fn is_string_option(
  option: glance.BitStringSegmentOption(glance.Pattern),
) -> Bool {
  case option {
    glance.Utf8Option
    | glance.Utf16Option
    | glance.Utf32Option
    | glance.Utf8CodepointOption
    | glance.Utf16CodepointOption
    | glance.Utf32CodepointOption -> True
    _ -> False
  }
}
