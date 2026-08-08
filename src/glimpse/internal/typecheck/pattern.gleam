import glance
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import glimpse/error
import glimpse/internal/typecheck/bit_string_segment
import glimpse/internal/typecheck/types

/// Check that a pattern is compatible with the expected type, returning the
/// environment extended with any variable bindings the pattern introduces.
/// The type store is threaded so that unification during variant matching can
/// constrain inference variables created elsewhere (e.g. unannotated function
/// parameters).
/// Whether a float literal's text denotes a representable value. The official
/// compiler rejects literals outside the IEEE double range, e.g. `1.8e308`.
pub fn float_is_in_range(value: String) -> Bool {
  let normalized = string.replace(value, "_", "")
  let normalized = case string.ends_with(normalized, ".") {
    True -> normalized <> "0"
    False -> normalized
  }
  case float.parse(normalized) {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn typecheck_pattern(
  environment: types.Environment,
  store: types.TypeStore,
  expected_type: types.Type,
  pattern: glance.Pattern,
) -> error.TypeCheckResult(#(types.TypeStore, types.Environment)) {
  case pattern {
    glance.PatternVariable(_, name) ->
      case name {
        "true" | "false" -> Error(error.LowercaseBoolPattern(name))
        _ -> bind_variable(environment, store, name, expected_type)
      }

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

    glance.PatternFloat(_, value) -> {
      case float_is_in_range(value) {
        False -> Error(error.FloatOutOfRange(value))
        True ->
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
        types.CustomType("gleam", "List", [element_type], option.None) ->
          Ok(#(store, element_type))
        _ -> {
          let #(store, element_type) = types.fresh_var(store)
          types.unify(
            store,
            environment,
            expected_type,
            types.CustomType("gleam", "List", [element_type], option.None),
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
            types.CustomType("gleam", "List", [element_type], option.None),
            tail_pattern,
          )
          |> result.map(fn(new_state) {
            let #(store, env) = new_state
            #(store, env)
          })
      }
    }

    glance.PatternVariant(_, module, constructor, arguments, with_spread) -> {
      use callable <- result.try(lookup_constructor(
        environment,
        module,
        constructor,
      ))
      case callable {
        types.CallableType(..) | types.GenericCallableType(..) -> {
          let #(store, parameters, position_labels, constructor_return) =
            types.instantiate_callable(store, callable)
          use store <- result.try(types.unify(
            store,
            environment,
            expected_type,
            constructor_return,
          ))
          // A `..` spread that redundantly names every field of a constructor
          // with labelled fields is "unnecessary" in real Gleam, but for an
          // unlabelled constructor the same pattern is accepted. An excess of
          // fields (spread or not) or a shortage without a spread is always an
          // error.
          case
            list.length(arguments) > list.length(parameters)
            || !with_spread
            && list.length(arguments) != list.length(parameters)
          {
            True ->
              Error(error.InvalidPatternArity(
                list.length(parameters),
                list.length(arguments),
              ))
            False ->
              case
                with_spread
                && list.length(arguments) == list.length(parameters)
                && dict.size(position_labels) > 0
              {
                True -> Error(error.UnnecessarySpread)
                False -> {
                  // Resolve the constructor parameters but do not generalise them:
                  // any still-unbound inference variable must remain free so the
                  // argument patterns can constrain it (e.g. `Error(Nil)` binding
                  // the payload to `Nil`). Polymorphism of bound variables is
                  // handled by `bind_variable` at the binding boundary.
                  let resolved_parameters =
                    list.map(parameters, fn(parameter) {
                      let #(_store, resolved) =
                        types.resolve_keep_rigid(store, parameter)
                      resolved
                    })
                  check_variant_arguments(
                    environment,
                    store,
                    arguments,
                    resolved_parameters,
                    position_labels,
                  )
                }
              }
          }
        }
        // Zero-field constructors (e.g. `True`, `Nil`, `None`) resolve directly
        // to their type rather than a callable.
        _ ->
          case arguments {
            [] -> {
              let #(store, callable) = types.instantiate(store, callable)
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

    glance.PatternAssignment(_, pattern, name) -> {
      use #(store, environment) <- result.try(bind_variable(
        environment,
        store,
        name,
        expected_type,
      ))
      use #(store, environment) <- result.try(typecheck_pattern(
        environment,
        store,
        expected_type,
        pattern,
      ))
      // An `as` binding of a constructor pattern refines the bound variable to
      // that variant, so field access on it resolves that variant's fields
      // (e.g. `[Fragment(..) as first, ..]` makes `first.children` valid).
      case pattern {
        glance.PatternVariant(_, module, constructor, _arguments, _spread) ->
          constructor_variant_index(environment, module, constructor)
          |> option.map(fn(index) {
            let refined = types.set_custom_type_variant(expected_type, index)
            let refined_environment =
              types.Environment(
                ..environment,
                scope: types.Scope(
                  ..environment.scope,
                  definitions: dict.insert(
                    environment.scope.definitions,
                    name,
                    refined,
                  ),
                ),
              )
            Ok(#(store, refined_environment))
          })
          |> option.unwrap(Ok(#(store, environment)))
        _ -> Ok(#(store, environment))
      }
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
        types.Var(_) | types.InferredReturn ->
          types.unify(store, environment, expected_type, types.StringType)
          |> result.try(fn(store) {
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
          })
          |> result.map_error(fn(_) {
            error.PatternMismatch(
              "string concatenation pattern",
              "String",
              types.to_string(environment, expected_type),
            )
          })
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
        types.BitArrayType -> check_segments(environment, store, segments)
        types.Var(_) | types.InferredReturn ->
          types.unify(store, environment, expected_type, types.BitArrayType)
          |> result.map(fn(store) {
            check_segments(environment, store, segments)
          })
          |> result.map_error(fn(_) {
            error.PatternMismatch(
              "bit array pattern",
              "BitArray",
              types.to_string(environment, expected_type),
            )
          })
          |> result.flatten
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

fn check_segments(
  environment: types.Environment,
  store: types.TypeStore,
  segments: List(
    #(glance.Pattern, List(glance.BitStringSegmentOption(glance.BitArraySize))),
  ),
) -> error.TypeCheckResult(#(types.TypeStore, types.Environment)) {
  let count = list.length(segments)
  let indexed =
    segments
    |> list.index_map(fn(segment, index) { #(segment, index == count - 1) })
  list.try_fold(indexed, #(store, environment), fn(state, entry) {
    let #(store, env) = state
    let #(#(pattern, options), is_last) = entry
    // Real Gleam restricts a pattern segment's options the same way it
    // restricts expressions, plus: a bare `bits`/`bytes` segment matches the
    // *rest* of the bit array, so it is only valid as the final segment, and
    // a utf segment cannot bind a plain variable (use `_` or a literal).
    use _ <- result.try(check_pattern_segment_options(options, is_last, pattern))
    // Literal sizes and units must be positive; variable sizes must be bound.
    use store <- result.try(check_pattern_size_options(
      environment,
      store,
      options,
    ))
    // A bit-string segment cannot assign a variable twice (`<<a as b>>`).
    use store <- result.try(check_segment_assignment(store, pattern))
    case pattern {
      // A string literal in a bit string matches its UTF-8 bytes, one Int
      // segment per byte (e.g. `<<"+", rest:bytes>>` matches byte 0x2B).
      glance.PatternString(_, _value) -> {
        case list.any(options, bit_string_segment.is_utf_option) {
          True -> typecheck_pattern(env, store, types.StringType, pattern)
          // Without a utf option the literal's bytes are fixed, so there is
          // nothing to constrain against the expected type.
          False -> Ok(#(store, env))
        }
      }
      _ ->
        typecheck_pattern(
          env,
          store,
          bit_string_segment.segment_type(options),
          pattern,
        )
    }
  })
}

/// Validate a pattern segment's options against real Gleam's rules: a
/// `bits`/`bytes` option without a size matches the rest of the bit array, so
/// it is only allowed on the final segment, and a utf-family segment cannot
/// bind a plain variable (the byte boundary cannot be inferred for an
/// unconstrained variable; `_` and literals are fine).
fn check_pattern_segment_options(
  options: List(glance.BitStringSegmentOption(glance.BitArraySize)),
  is_last: Bool,
  pattern: glance.Pattern,
) -> error.TypeCheckResult(Nil) {
  let has_size =
    list.any(options, fn(option) {
      case option {
        glance.SizeOption(_) | glance.SizeValueOption(_) -> True
        _ -> False
      }
    })
  let has_bits_or_bytes =
    list.any(options, fn(option) {
      case option {
        glance.BitsOption | glance.BytesOption -> True
        _ -> False
      }
    })
  let has_utf =
    list.any(options, fn(option) {
      case option {
        glance.Utf8Option | glance.Utf16Option | glance.Utf32Option -> True
        _ -> False
      }
    })
  let is_variable = case pattern {
    glance.PatternVariable(_, _) -> True
    _ -> False
  }
  case !is_last && has_bits_or_bytes && !has_size {
    True -> Error(error.InvalidBitStringSegment("bits"))
    False ->
      case has_utf && is_variable {
        True -> Error(error.InvalidBitStringSegment("utf8"))
        False -> Ok(Nil)
      }
  }
}

fn bind_variable(
  environment: types.Environment,
  store: types.TypeStore,
  name: String,
  type_: types.Type,
) -> error.TypeCheckResult(#(types.TypeStore, types.Environment)) {
  // A binding is polymorphic only through the *named* generics its value
  // already carries (from annotations); inference variables are bound
  // monomorphically, matching real Gleam (`let xs = []` cannot later be used
  // as both a `List(Int)` and a `List(String)`). Shadowing is allowed (Gleam
  // permits rebinding in a new scope), so the definition is simply
  // overwritten. Rigid type parameters stay rigid: binding them as-is keeps
  // `case xs, ys { [x, ..], [y, ..] -> x == y }` from unifying `a` with `b`.
  Ok(#(store, types.add_or_update_def_in_env(environment, name, type_)))
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
      let definitions = fn(alias: String) {
        case dict.get(environment.imports.module_imports, alias) {
          Ok(types.NamespaceType(definitions, _custom_types)) ->
            option.Some(definitions)
          _ -> option.None
        }
      }
      // The type's module field carries the full module name (e.g.
      // `gleam/otp/actor`) while imports register namespaces under the alias
      // used in source (`actor`), so resolve through `import_names`.
      case
        definitions(module_name)
        |> option.or(
          definitions(types.module_access_name(environment, module_name)),
        )
      {
        option.Some(module_definitions) ->
          dict.get(module_definitions, constructor)
          |> result.replace_error(error.InvalidName(constructor))
        option.None -> Error(error.InvalidName(constructor))
      }
    }
  }
}

/// Whether a pattern (recursively) binds a variable with the given name. Used
/// to detect when a constructor pattern shadows the subject variable it is
/// matched against.
pub fn pattern_binds_name(pattern: glance.Pattern, name: String) -> Bool {
  case pattern {
    glance.PatternVariable(_, bound) -> bound == name
    glance.PatternAssignment(_, inner, bound) ->
      bound == name || pattern_binds_name(inner, name)
    glance.PatternDiscard(_, _) -> False
    glance.PatternInt(_, _) -> False
    glance.PatternFloat(_, _) -> False
    glance.PatternString(_, _) -> False
    glance.PatternTuple(_, elements) ->
      list.any(elements, fn(p) { pattern_binds_name(p, name) })
    glance.PatternList(_, elements, tail) ->
      list.any(elements, fn(p) { pattern_binds_name(p, name) })
      || case tail {
        option.Some(p) -> pattern_binds_name(p, name)
        option.None -> False
      }
    glance.PatternBitString(_, segments) ->
      list.any(segments, fn(pair) {
        let #(p, _options) = pair
        pattern_binds_name(p, name)
      })
    glance.PatternConcatenate(_, _prefix, prefix_name, rest_name) ->
      assignment_name_equals(prefix_name, name)
      || assignment_name_equals(option.Some(rest_name), name)
    glance.PatternVariant(_, _module, _constructor, arguments, _spread) ->
      list.any(arguments, fn(field) {
        let pattern = case field {
          glance.LabelledField(_, _, item) -> item
          glance.ShorthandField(label, _) ->
            glance.PatternVariable(glance.Span(0, 0), label)
          glance.UnlabelledField(item) -> item
        }
        pattern_binds_name(pattern, name)
      })
  }
}

fn assignment_name_equals(
  name: option.Option(glance.AssignmentName),
  expected: String,
) -> Bool {
  case name {
    option.Some(glance.Named(actual)) -> actual == expected
    _ -> False
  }
}

/// The variant index a constructor pattern matches, if it resolves to a record
/// constructor. Used to refine the subject variable's type so field access on
/// it uses the correct constructor's field types.
pub fn constructor_variant_index(
  environment: types.Environment,
  module: option.Option(String),
  constructor: String,
) -> Option(Int) {
  lookup_constructor(environment, module, constructor)
  |> result.map(fn(type_) {
    case type_ {
      types.CallableType(_parameters, _labels, return) ->
        types.custom_type_inferred_variant(return)
      types.GenericCallableType(_parameters, _labels, return, _) ->
        types.custom_type_inferred_variant(return)
      _ -> types.custom_type_inferred_variant(type_)
    }
  })
  |> result.unwrap(option.None)
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
      glance.LabelledField(_label, _label_location, pattern) -> {
        use #(store, env) <- result.try(typecheck_pattern(
          env,
          store,
          expected,
          pattern,
        ))
        Ok(#(store, env, positional_count))
      }
      glance.ShorthandField(label, _location) ->
        bind_variable(env, store, label, expected)
        |> result.map(fn(state) {
          let #(store, env) = state
          #(store, env, positional_count)
        })
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
    glance.LabelledField(label, _, _) | glance.ShorthandField(label, _) -> {
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

/// Pattern bit-string segment options must use positive literal sizes and
/// units. The `size(...)` form in a pattern is `SizeValueOption` carrying the
/// `BitArraySize`; a literal negative size is caught here.
/// A segment like `<<a as b>>` binds the name twice and is an error.
fn check_segment_assignment(
  store: types.TypeStore,
  pattern: glance.Pattern,
) -> error.TypeCheckResult(types.TypeStore) {
  case pattern {
    glance.PatternAssignment(_, _inner, _name) ->
      Error(error.DoubleVariableAssignment)
    _ -> Ok(store)
  }
}

fn check_pattern_size_options(
  environment: types.Environment,
  store: types.TypeStore,
  options: List(glance.BitStringSegmentOption(glance.BitArraySize)),
) -> error.TypeCheckResult(types.TypeStore) {
  list.try_fold(options, store, fn(store, option) {
    case option {
      glance.SizeValueOption(size) ->
        check_bit_array_size_positive(store, size)
        |> result.try(fn(store) {
          check_bit_array_size_variables(environment, store, size)
        })
      _ -> Ok(store)
    }
  })
}

/// A `size(...)` argument that is a variable reference must name a variable in
/// scope (`<<value:size(bytes)>>`), mirroring the expression side where the
/// size expression is typechecked.
fn check_bit_array_size_variables(
  environment: types.Environment,
  store: types.TypeStore,
  size: glance.BitArraySize,
) -> error.TypeCheckResult(types.TypeStore) {
  case size {
    glance.BitArraySizeVariable(_, name) ->
      case types.lookup_variable_type(environment, name) {
        Ok(_) -> Ok(store)
        Error(_) -> Error(error.InvalidName(name))
      }
    glance.BitArraySizeBinaryOperator(_, _, left, right) ->
      check_bit_array_size_variables(environment, store, left)
      |> result.try(fn(store) {
        check_bit_array_size_variables(environment, store, right)
      })
    glance.BitArraySizeBlock(_, inner) ->
      check_bit_array_size_variables(environment, store, inner)
    _ -> Ok(store)
  }
}

fn check_bit_array_size_positive(
  store: types.TypeStore,
  size: glance.BitArraySize,
) -> error.TypeCheckResult(types.TypeStore) {
  case size {
    glance.BitArraySizeInt(_, value) ->
      case int.parse(value) {
        Ok(n) if n <= 0 -> Error(error.InvalidBitStringSegment("size"))
        Ok(_) -> Ok(store)
        Error(_) -> Ok(store)
      }
    _ -> Ok(store)
  }
}
