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
/// The type store is threaded so that unification during variant matching can
/// constrain inference variables created elsewhere (e.g. unannotated function
/// parameters).
pub fn typecheck_pattern(
  environment: types.Environment,
  store: types.TypeStore,
  expected_type: types.Type,
  pattern: glance.Pattern,
) -> error.TypeCheckResult(#(types.TypeStore, types.Environment)) {
  case pattern {
    glance.PatternVariable(_, name) ->
      bind_variable(environment, store, name, expected_type)

    glance.PatternDiscard(_, _) -> Ok(#(store, environment))

    glance.PatternInt(_, _) -> {
      types.unify(store, environment, expected_type, types.IntType)
      |> result.map(fn(store) { #(store, environment) })
      |> result.map_error(fn(_) {
        error.PatternMismatch(
          "int pattern",
          "Int",
          types.to_string(environment, expected_type),
        )
      })
    }

    glance.PatternFloat(_, _) -> {
      types.unify(store, environment, expected_type, types.FloatType)
      |> result.map(fn(store) { #(store, environment) })
      |> result.map_error(fn(_) {
        error.PatternMismatch(
          "float pattern",
          "Float",
          types.to_string(environment, expected_type),
        )
      })
    }

    glance.PatternString(_, _) -> {
      types.unify(store, environment, expected_type, types.StringType)
      |> result.map(fn(store) { #(store, environment) })
      |> result.map_error(fn(_) {
        error.PatternMismatch(
          "string pattern",
          "String",
          types.to_string(environment, expected_type),
        )
      })
    }

    glance.PatternTuple(_, elements) -> {
      use #(store, expected_elements) <- result.try(case expected_type {
        types.TupleType(tuple_elements) -> Ok(#(store, tuple_elements))
        _ -> {
          let #(store, expected_elements) =
            types.fresh_vars(store, list.length(elements))
          types.unify(
            store,
            environment,
            expected_type,
            types.TupleType(expected_elements),
          )
          |> result.map(fn(store) { #(store, expected_elements) })
          |> result.map_error(fn(_) {
            tuple_mismatch(environment, expected_type)
          })
        }
      })
      case list.length(expected_elements) == list.length(elements) {
        True ->
          list.try_fold(
            list.zip(elements, expected_elements),
            #(store, environment),
            fn(state, pair) {
              let #(store, env) = state
              let #(element, expected) = pair
              typecheck_pattern(env, store, expected, element)
              |> result.map(fn(new_state) {
                let #(store, env) = new_state
                #(store, env)
              })
            },
          )
        False -> Error(tuple_mismatch(environment, expected_type))
      }
    }

    glance.PatternList(_, elements, tail) -> {
      use #(store, element_type) <- result.try(case expected_type {
        types.ListType(element_type) -> Ok(#(store, element_type))
        _ -> {
          let #(store, element_type) = types.fresh_var(store)
          types.unify(
            store,
            environment,
            expected_type,
            types.ListType(element_type),
          )
          |> result.map(fn(store) { #(store, element_type) })
          |> result.map_error(fn(_) {
            error.PatternMismatch(
              "list pattern",
              "List",
              types.to_string(environment, expected_type),
            )
          })
        }
      })
      use #(store, environment) <- result.try(fold_patterns(
        environment,
        store,
        element_type,
        elements,
      ))
      case tail {
        option.None -> Ok(#(store, environment))
        option.Some(tail_pattern) ->
          typecheck_pattern(
            environment,
            store,
            types.ListType(element_type),
            tail_pattern,
          )
          |> result.map(fn(new_state) {
            let #(store, env) = new_state
            #(store, env)
          })
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
            types.instantiate_callable(store, callable)
          echo "PATTERN-VARIANT "
            <> constructor
            <> " expected="
            <> types.to_string(environment, expected_type)
            <> " ret="
            <> types.to_string(environment, constructor_return)
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
            store,
            arguments,
            resolved_parameters,
            position_labels,
          )
        }
        // Zero-field constructors (e.g. `True`, `Nil`, `None`) resolve directly
        // to their type rather than a callable.
        _ ->
          case arguments {
            [] -> {
              let #(store, callable) = types.instantiate(store, callable)
              echo "PATTERN-ZERO "
                <> constructor
                <> " expected="
                <> types.to_string(environment, expected_type)
                <> " callable="
                <> types.to_string(environment, callable)
              types.unify(store, environment, expected_type, callable)
              |> result.map(fn(store) { #(store, environment) })
              |> result.map_error(fn(_) {
                error.PatternMismatch(
                  constructor,
                  types.to_string(environment, callable),
                  types.to_string(environment, expected_type),
                )
              })
            }
            _ ->
              Error(error.NotCallable(types.to_string(environment, callable)))
          }
      }
    }

    glance.PatternAssignment(_, attern, name) -> {
      use #(store, environment) <- result.try(bind_variable(
        environment,
        store,
        name,
        expected_type,
      ))
      typecheck_pattern(environment, store, expected_type, attern)
    }

    glance.PatternConcatenate(_, _prefix, prefix_name, rest_name) -> {
      case expected_type {
        types.StringType -> {
          use #(store, environment) <- result.try(bind_assignment_name(
            environment,
            store,
            prefix_name,
          ))
          case rest_name {
            glance.Named(name) ->
              bind_variable(environment, store, name, types.StringType)
            glance.Discarded(_) -> Ok(#(store, environment))
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
          list.try_fold(segments, #(store, environment), fn(state, segment) {
            let #(store, env) = state
            let #(pattern, options) = segment
            typecheck_pattern(
              env,
              store,
              bit_string_segment_type(options),
              pattern,
            )
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
  store: types.TypeStore,
  name: String,
  type_: types.Type,
) -> error.TypeCheckResult(#(types.TypeStore, types.Environment)) {
  // Generalise at the binding boundary (the HM "let" point): any inference
  // variables still unbound here become named type variables, so the binding
  // is polymorphic and later unifications cannot leak into it. Shadowing is
  // allowed (Gleam permits rebinding in a new scope), so the definition is
  // simply overwritten.
  let generalised = types.generalise(store, type_)
  Ok(#(store, types.add_or_update_def_in_env(environment, name, generalised)))
}

fn fold_patterns(
  environment: types.Environment,
  store: types.TypeStore,
  expected_type: types.Type,
  patterns: List(glance.Pattern),
) -> error.TypeCheckResult(#(types.TypeStore, types.Environment)) {
  list.try_fold(patterns, #(store, environment), fn(state, pattern) {
    let #(store, env) = state
    typecheck_pattern(env, store, expected_type, pattern)
  })
}

fn tuple_mismatch(
  environment: types.Environment,
  expected_type: types.Type,
) -> error.TypeCheckError {
  error.PatternMismatch(
    "tuple pattern",
    types.to_string(environment, expected_type),
    "tuple",
  )
}

fn lookup_constructor(
  environment: types.Environment,
  module: option.Option(String),
  constructor: String,
) -> error.TypeCheckResult(types.Type) {
  case module {
    option.None -> types.lookup_variable_type(environment, constructor)
    option.Some(module_name) -> {
      case dict.get(environment.module_imports, module_name) {
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
  store: types.TypeStore,
  arguments: List(glance.Field(glance.Pattern)),
  parameters: List(types.Type),
  position_labels: dict.Dict(String, Int),
) -> error.TypeCheckResult(#(types.TypeStore, types.Environment)) {
  list.try_fold(arguments, #(store, environment, 0), fn(state, field) {
    let #(store, env, positional_count) = state
    use expected <- result.try(variant_field_expected_type(
      env,
      parameters,
      position_labels,
      positional_count,
      field,
    ))
    case field {
      glance.UnlabelledField(pattern) -> {
        use #(store, env) <- result.try(typecheck_pattern(
          env,
          store,
          expected,
          pattern,
        ))
        Ok(#(store, env, positional_count + 1))
      }
      glance.LabelledField(_label, pattern) -> {
        use #(store, env) <- result.try(typecheck_pattern(
          env,
          store,
          expected,
          pattern,
        ))
        Ok(#(store, env, positional_count))
      }
      glance.ShorthandField(_label) -> Ok(#(store, env, positional_count))
    }
  })
  |> result.map(fn(state) {
    let #(store, environment, _positional_count) = state
    #(store, environment)
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
  store: types.TypeStore,
  name: option.Option(glance.AssignmentName),
) -> error.TypeCheckResult(#(types.TypeStore, types.Environment)) {
  case name {
    option.None -> Ok(#(store, environment))
    option.Some(glance.Named(bound_name)) ->
      bind_variable(environment, store, bound_name, types.StringType)
    option.Some(glance.Discarded(_)) -> Ok(#(store, environment))
  }
}

fn bit_string_segment_type(
  options: List(glance.BitStringSegmentOption(glance.Pattern)),
) -> types.Type {
  case list.any(options, is_utf_option) {
    True -> types.StringType
    False ->
      case list.any(options, is_codepoint_option) {
        True -> types.CustomType("prelude", "UtfCodepoint", [])
        False ->
          case list.any(options, is_bit_option) {
            True -> types.BitArrayType
            False ->
              case list.any(options, is_float_option) {
                True -> types.FloatType
                False -> types.IntType
              }
          }
      }
  }
}

fn is_utf_option(
  option: glance.BitStringSegmentOption(glance.Pattern),
) -> Bool {
  case option {
    glance.Utf8Option | glance.Utf16Option | glance.Utf32Option -> True
    _ -> False
  }
}

fn is_codepoint_option(
  option: glance.BitStringSegmentOption(glance.Pattern),
) -> Bool {
  case option {
    glance.Utf8CodepointOption
    | glance.Utf16CodepointOption
    | glance.Utf32CodepointOption -> True
    _ -> False
  }
}

fn is_bit_option(
  option: glance.BitStringSegmentOption(glance.Pattern),
) -> Bool {
  case option {
    glance.BytesOption | glance.BitsOption -> True
    _ -> False
  }
}

fn is_float_option(
  option: glance.BitStringSegmentOption(glance.Pattern),
) -> Bool {
  case option {
    glance.FloatOption -> True
    _ -> False
  }
}
