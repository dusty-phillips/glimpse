import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/set
import gleam/string
import glimpse/error
import glimpse/internal/typecheck/bit_string_segment
import glimpse/internal/typecheck/exhaustive
import glimpse/internal/typecheck/functions
import glimpse/internal/typecheck/pattern
import glimpse/internal/typecheck/types.{
  type Environment, type Type, type TypeStore, Environment,
}

/// Typecheck a sequence of statements, threading the environment and type store
/// through each one. Returns the type of the final statement, or Nil if the
/// block is empty.
///
/// A `use` statement desugars to a call `f(args, fn(..) { .. })` whose value is
/// `f`'s return type, and every statement after it becomes the callback body.
/// So a `use` consumes the rest of the block: the block's type is the use
/// call's return type, and the trailing statements are checked as the callback
/// body (which may itself contain further nested `use` statements).
pub fn block(
  environment: Environment,
  store: TypeStore,
  statements: List(glance.Statement),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  case statements {
    [] -> Ok(#(store, types.NilType))
    [glance.Use(_, patterns, function_expr), ..rest] ->
      use_statement(environment, store, patterns, function_expr, rest)
      |> result.map(fn(state) {
        let #(store, _env, type_) = state
        #(store, type_)
      })
    [stmnt, ..rest] -> {
      use #(store, env, type_) <- result.try(statement(
        environment,
        store,
        stmnt,
      ))
      case rest {
        [] -> Ok(#(store, type_))
        _ -> block(env, store, rest)
      }
    }
  }
}

/// Typecheck a single statement, returning the updated environment, the
/// threaded type store, and the statement's type.
pub fn statement(
  environment: Environment,
  store: TypeStore,
  statement: glance.Statement,
) -> error.TypeCheckResult(#(TypeStore, Environment, Type)) {
  case statement {
    glance.Expression(expr) ->
      expression(environment, store, expr)
      |> result.map(fn(state) {
        let #(store, type_) = state
        #(store, environment, type_)
      })

    glance.Assignment(_, kind, pat, annotation, value_expression) -> {
      use #(store, value_type) <- result.try(expression(
        environment,
        store,
        value_expression,
      ))

      let annotated_type_result = case annotation {
        option.None -> Ok(#(store, option.None))
        option.Some(annotation) ->
          types.type_with_store(environment, store, annotation)
          |> result.map(fn(state) {
            let #(store, type_) = state
            #(store, option.Some(type_))
          })
      }

      use #(store, annotated_type) <- result.try(annotated_type_result)

      let checked_type = case annotated_type {
        option.Some(annotated) -> {
          types.unify(store, environment, value_type, annotated)
          |> result.map(fn(store) { #(store, annotated) })
          |> result.map_error(fn(_) {
            error.InvalidAnnotation(
              types.to_string(environment, value_type),
              types.to_string(environment, annotated),
              type_name(pat),
            )
          })
        }
        option.None -> Ok(#(store, value_type))
      }

      use #(store, type_) <- result.try(checked_type)

      case kind {
        glance.Let -> {
          use _ <- result.try(validate_let_pattern_variables(pat))
          pattern.typecheck_pattern(environment, store, type_, pat)
          |> pattern_must_be_irrefutable(environment, type_, pat)
          |> result.map(fn(state) {
            let #(store, env) = state
            #(store, env, type_)
          })
        }
        glance.LetAssert(message) -> {
          // The message is checked before the pattern binds its variables, so
          // the pattern's bindings are not in scope inside it.
          use store <- result.try(case message {
            option.None -> Ok(store)
            option.Some(message_expr) ->
              expression(environment, store, message_expr)
              |> result.try(fn(state) {
                let #(store, message_type) = state
                types.unify(store, environment, message_type, types.StringType)
              })
          })
          use _ <- result.try(validate_let_pattern_variables(pat))
          use #(store, env) <- result.try(pattern.typecheck_pattern(
            environment,
            store,
            type_,
            pat,
          ))
          // A block ending in `let assert pat = expr` has the type of `expr`,
          // so a case branch like `Error(_) -> { let assert Ok(_) = delete(p) }`
          // unifies with a sibling branch returning `Ok(Nil)`.
          Ok(#(store, env, type_))
        }
      }
    }

    glance.Assert(_, expression_, _message) -> {
      use #(store, type_) <- result.try(expression(
        environment,
        store,
        expression_,
      ))
      case types.unify(store, environment, type_, types.BoolType) {
        Ok(store) -> Ok(#(store, environment, types.NilType))
        Error(_) ->
          Error(error.InvalidType(
            types.to_string(environment, type_),
            "Bool",
            "the assert statement requires a Bool",
          ))
      }
    }

    // `use` is only ever encountered at the head of a block, where `block`
    // handles it directly and passes the continuation on; this arm is never
    // reached.
    glance.Use(_, patterns, function_expr) ->
      use_statement(environment, store, patterns, function_expr, [])
      |> result.map(fn(state) {
        let #(store, env, type_) = state
        #(store, env, type_)
      })
  }
}

fn type_name(pat: glance.Pattern) -> String {
  case pat {
    glance.PatternVariable(_, name) -> name
    glance.PatternDiscard(_, name) -> name
    _ -> ""
  }
}

/// Extract the parameters, labels, and return type of a call target, so a call
/// can be checked against them. A target that is a bare unbound variable (an
/// unannotated higher-order parameter) is constrained to a fresh callable
/// taking the given number of arguments.
fn callable_parts(
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

/// Typecheck a `use` statement. The use function must be a callable whose last
/// parameter is itself a function that takes the bound variables as arguments.
/// The result of the use expression is the return type of that inner function.
fn use_statement(
  environment: Environment,
  store: TypeStore,
  patterns: List(glance.UsePattern),
  function_expr: glance.Expression,
  continuation: List(glance.Statement),
) -> error.TypeCheckResult(#(TypeStore, Environment, Type)) {
  case function_expr {
    glance.Call(_, target, arguments) ->
      use_call(environment, store, patterns, target, arguments, continuation)
    _ ->
      use_statement_with_type(
        environment,
        store,
        patterns,
        function_expr,
        continuation,
      )
  }
}

/// Check the continuation statements (the callback body) of a `use` statement
/// against the callback's declared return type, returning the block's type
/// resolved to a concrete form. The block is checked in a nested `block` so
/// that further `use` statements consume their own trailing statements, exactly
/// as the desugared callback would.
fn check_continuation(
  environment: Environment,
  store: TypeStore,
  callback_return: types.Type,
  return: types.Type,
  continuation: List(glance.Statement),
) -> error.TypeCheckResult(#(TypeStore, Environment, types.Type)) {
  use #(store, continuation_type) <- result.try(block(
    environment,
    store,
    continuation,
  ))
  use store <- result.try(types.unify(
    store,
    environment,
    callback_return,
    continuation_type,
  ))
  let #(store, resolved) = types.resolve(store, return)
  Ok(#(store, environment, resolved))
}

/// Typecheck a `use` statement where the function is a call, e.g.
/// `use y <- with_x(10)`. The given arguments are checked against all but the
/// last parameter of the function; the last parameter is the callback that the
/// `use` expression provides. The continuation statements are the callback's
/// body, so their type must agree with the callback's declared return type.
/// The statement's type is the call's return type.
fn use_call(
  environment: Environment,
  store: TypeStore,
  patterns: List(glance.UsePattern),
  target: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
  continuation: List(glance.Statement),
) -> error.TypeCheckResult(#(TypeStore, Environment, Type)) {
  use #(store, glimpse_target) <- result.try(expression(
    environment,
    store,
    target,
  ))

  case glimpse_target {
    types.CallableType(..) | types.GenericCallableType(..) -> {
      let #(store, parameters, labels, return) =
        types.instantiate_callable(store, glimpse_target)

      // The `use` callback is appended as a trailing positional argument, so
      // after label/position alignment it occupies the parameter position that
      // is not claimed by a labelled argument and not filled by an explicit
      // positional argument. The callback is not necessarily the last
      // parameter: labelled arguments may follow it in the signature.
      let callback_position =
        use_callback_position(arguments, labels, list.length(parameters))
      let given_parameters = remove_at(parameters, callback_position)
      let given_labels = remap_labels(labels, callback_position)

      use #(store, _argument_types) <- result.try(check_arguments(
        environment,
        store,
        arguments,
        given_parameters,
        given_labels,
      ))

      let callback_parameter =
        list.drop(parameters, up_to: callback_position)
        |> list.first
        |> result.unwrap(types.IntType)

      // Fold the use patterns against the callback parameter only after the
      // explicit arguments are unified, so the callback's types are resolved
      // before they are generalised into the bound pattern variables.
      use #(store, env, callback_return) <- result.try(fold_use_patterns(
        environment,
        store,
        patterns,
        callback_parameter,
      ))

      // The statements after the `use` are the callback body, checked against
      // the callback's declared return type.
      check_continuation(env, store, callback_return, return, continuation)
    }
    _ -> Error(error.NotCallable(types.to_string(environment, glimpse_target)))
  }
}

/// The parameter index a `use` statement's implicit callback occupies. The
/// callback is appended as the final positional argument, so it fills the
/// parameter position that is neither claimed by a labelled or shorthand
/// argument nor already filled by an explicit positional argument.
fn use_callback_position(
  fields: List(glance.Field(glance.Expression)),
  position_labels: dict.Dict(String, Int),
  param_count: Int,
) -> Int {
  let positional_count =
    list.fold(fields, 0, fn(count, field) {
      case field {
        glance.UnlabelledField(_) -> count + 1
        _ -> count
      }
    })
  let claimed =
    list.fold(fields, set.new(), fn(acc, field) {
      case field {
        glance.LabelledField(label, _, _) | glance.ShorthandField(label, _) ->
          case dict.get(position_labels, label) {
            Ok(position) -> set.insert(acc, position)
            Error(_) -> acc
          }
        _ -> acc
      }
    })
  // Walk the parameter positions; the callback is the `positional_count`-th
  // unclaimed position (0-indexed), i.e. the next one after the explicit
  // positional arguments have claimed their slots.
  let #(_, position) =
    list.fold_until(
      index_range(param_count),
      #(positional_count, 0),
      fn(state, position) {
        let #(remaining, _) = state
        case set.contains(claimed, position) {
          True -> list.Continue(state)
          False ->
            case remaining == 0 {
              True -> list.Stop(#(remaining, position))
              False -> list.Continue(#(remaining - 1, 0))
            }
        }
      },
    )
  position
}

/// Remove the element at `index` from a list.
fn remove_at(items: List(a), index: Int) -> List(a) {
  list.append(
    list.take(items, up_to: index),
    list.drop(items, up_to: index + 1),
  )
}

/// Remap label positions after a parameter has been removed: positions after
/// the removed index shift down by one so they still address the reduced list.
fn remap_labels(
  labels: dict.Dict(String, Int),
  removed_index: Int,
) -> dict.Dict(String, Int) {
  dict.map_values(labels, fn(_label, position) {
    case position > removed_index {
      True -> position - 1
      False -> position
    }
  })
}

/// Typecheck a `use` statement whose function is a bare name or other
/// non-call expression, e.g. `use value <- maybe`. The whole expression must be
/// a callable taking the use patterns plus a callback.
fn use_statement_with_type(
  environment: Environment,
  store: TypeStore,
  patterns: List(glance.UsePattern),
  function_expr: glance.Expression,
  continuation: List(glance.Statement),
) -> error.TypeCheckResult(#(TypeStore, Environment, Type)) {
  use #(store, target_type) <- result.try(expression(
    environment,
    store,
    function_expr,
  ))

  case target_type {
    types.CallableType(parameters, _, return)
    | types.GenericCallableType(parameters, _, return, _) -> {
      case list.length(parameters) == 1 {
        False -> Error(error.InvalidUse(list.length(patterns)))
        True -> {
          let callback_parameter =
            list.last(parameters) |> result.unwrap(types.IntType)
          use #(store, env, callback_return) <- result.try(fold_use_patterns(
            environment,
            store,
            patterns,
            callback_parameter,
          ))
          check_continuation(env, store, callback_return, return, continuation)
        }
      }
    }
    _ -> Error(error.NotCallable(types.to_string(environment, target_type)))
  }
}

/// Fold the use patterns against the callback's parameter types. The callback
/// parameter is the one the `use` statement's implicit trailing argument
/// occupies after argument alignment, not necessarily the last parameter.
fn fold_use_patterns(
  environment: Environment,
  store: TypeStore,
  patterns: List(glance.UsePattern),
  callback_parameter: types.Type,
) -> error.TypeCheckResult(#(TypeStore, Environment, Type)) {
  let callback_types = case callback_parameter {
    types.CallableType(callback_params, _, callback_return) ->
      Ok(#(callback_params, callback_return))
    types.GenericCallableType(callback_params, _, callback_return, _) ->
      Ok(#(callback_params, callback_return))
    _ ->
      Error(error.NotCallable(types.to_string(environment, callback_parameter)))
  }
  use #(callback_params, callback_return) <- result.try(callback_types)

  case list.length(callback_params) == list.length(patterns) {
    False -> Error(error.InvalidUse(list.length(patterns)))
    True ->
      list.try_fold(
        list.zip(patterns, callback_params),
        #(store, environment),
        fn(state, pair) {
          let #(store, env) = state
          let #(use_pattern, type_) = pair
          case use_pattern.annotation {
            option.None ->
              pattern.typecheck_pattern(env, store, type_, use_pattern.pattern)
              |> pattern_must_be_irrefutable(env, type_, use_pattern.pattern)
            option.Some(annotation) -> {
              use #(store, annotated) <- result.try(types.type_with_store(
                env,
                store,
                annotation,
              ))
              use store <- result.try(types.unify(store, env, type_, annotated))
              pattern.typecheck_pattern(
                env,
                store,
                annotated,
                use_pattern.pattern,
              )
              |> pattern_must_be_irrefutable(
                env,
                annotated,
                use_pattern.pattern,
              )
            }
          }
        },
      )
      |> result.map(fn(state) {
        let #(store, env) = state
        #(store, env, callback_return)
      })
  }
}

/// `use <-` binds a single callback-argument value, so its pattern must be
/// irrefutable; a refutable pattern (e.g. `use Ok(x) <- ..`) crashes on some
/// values. Only reject when the pattern itself has already typechecked.
fn pattern_must_be_irrefutable(
  checked: error.TypeCheckResult(#(types.TypeStore, types.Environment)),
  environment: types.Environment,
  type_: types.Type,
  pattern: glance.Pattern,
) -> error.TypeCheckResult(#(types.TypeStore, types.Environment)) {
  case checked {
    Error(check_error) -> Error(check_error)
    Ok(state) -> {
      let #(store, state_environment) = state
      let #(store, resolved) = types.resolve(store, type_)
      case resolved {
        types.InferredReturn | types.Var(_) ->
          // During the first body pass a subject type may still be the
          // placeholder for a callee whose inferred signature is not final
          // yet. Defer the irrefutability check to the second pass, which
          // sees the final signatures.
          case environment.defer_unknown {
            True -> Ok(state)
            False ->
              check_pattern_is_irrefutable(
                state_environment,
                store,
                resolved,
                pattern,
              )
          }
        _ ->
          check_pattern_is_irrefutable(
            state_environment,
            store,
            resolved,
            pattern,
          )
      }
    }
  }
}

fn check_pattern_is_irrefutable(
  environment: types.Environment,
  store: types.TypeStore,
  type_: types.Type,
  pattern: glance.Pattern,
) -> error.TypeCheckResult(#(types.TypeStore, types.Environment)) {
  case exhaustive.check(environment, [type_], [[pattern]]) {
    option.Some(missing) ->
      Error(error.InexhaustivePattern(string.join(missing, "\n")))
    option.None -> Ok(#(store, environment))
  }
}

/// Resolve subject types against the current store so unbound inference
/// variables that the clause patterns have since unified (e.g. an unannotated
/// parameter matched against `[first, ..rest]`) are seen as their concrete
/// shape by the exhaustiveness check.
fn resolve_subjects(
  store: types.TypeStore,
  subject_types: List(types.Type),
) -> List(types.Type) {
  list.map(subject_types, fn(type_) {
    let #(_store, resolved) = types.resolve(store, type_)
    resolved
  })
}

/// Typecheck an expression and return its type.
pub fn expression(
  environment: Environment,
  store: TypeStore,
  expr: glance.Expression,
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  typecheck_with_expected(environment, store, expr, option.None)
}

/// Typecheck an expression, optionally against an expected type.
///
/// The expected type is propagated only into call arguments and anonymous
/// function parameters. It binds inferred (unannotated) lambda parameters to
/// the parameter types of the callable they are passed to, so that field
/// accesses and other type-directed sub-expressions inside a callback body
/// resolve correctly even when the parameter type would otherwise remain an
/// unbound inference variable (e.g. `result.map(expr, fn(x) { x.location })`).
fn typecheck_with_expected(
  environment: Environment,
  store: TypeStore,
  expr: glance.Expression,
  expected: option.Option(Type),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  case expr {
    glance.Int(_, _) -> Ok(#(store, types.IntType))
    glance.Float(_, value) ->
      case pattern.float_is_in_range(value) {
        True -> Ok(#(store, types.FloatType))
        False -> Error(error.FloatOutOfRange(value))
      }
    glance.String(_, _) -> Ok(#(store, types.StringType))
    glance.Variable(_, "Nil") -> Ok(#(store, types.NilType))
    glance.Variable(_, "True") | glance.Variable(_, "False") ->
      Ok(#(store, types.BoolType))
    glance.Variable(_, name) ->
      types.lookup_variable_type(environment, name)
      |> result.map(fn(type_) {
        // Instantiate so generic values (constructors, polymorphic bindings)
        // get fresh variables at each use site.
        let #(store, type_) = types.instantiate(store, type_)
        #(store, type_)
      })

    glance.NegateInt(_, int_expr) -> {
      use #(store, got) <- result.try(expression(environment, store, int_expr))
      case types.unify(store, environment, got, types.IntType) {
        Ok(store) -> Ok(#(store, types.IntType))
        Error(_) ->
          Error(error.InvalidType(
            types.to_string(environment, got),
            "Int",
            "- can only negate Int",
          ))
      }
    }

    glance.NegateBool(_, bool_expr) -> {
      use #(store, got) <- result.try(expression(environment, store, bool_expr))
      case types.unify(store, environment, got, types.BoolType) {
        Ok(store) -> Ok(#(store, types.BoolType))
        Error(_) ->
          Error(error.InvalidType(
            types.to_string(environment, got),
            "Bool",
            "! can only negate Bool",
          ))
      }
    }

    glance.Block(_, statements) -> block(environment, store, statements)

    glance.Panic(_, _) -> Ok(#(store, types.GenericTypeVariable("todo")))
    glance.Todo(_, _) -> Ok(#(store, types.GenericTypeVariable("todo")))

    glance.Tuple(_, elements) -> {
      use #(store, types_rev) <- result.try(
        list.try_fold(elements, #(store, []), fn(state, element) {
          let #(store, reversed) = state
          expression(environment, store, element)
          |> result.map(fn(state) {
            let #(store, type_) = state
            #(store, [type_, ..reversed])
          })
        }),
      )
      Ok(#(store, types.TupleType(list.reverse(types_rev))))
    }

    glance.TupleIndex(_, tuple_expr, index) -> {
      use #(store, tuple_type) <- result.try(expression(
        environment,
        store,
        tuple_expr,
      ))
      case tuple_type {
        types.TupleType(elements) ->
          list.drop(elements, up_to: index)
          |> list.first
          |> result.replace_error(error.UnexpectedType(
            types.to_string(environment, tuple_type),
            "a tuple with an element at index " <> int.to_string(index),
          ))
          |> result.map(fn(element) { #(store, element) })
        _ -> {
          case types.extend_tuple(store, tuple_type, index) {
            Ok(state) -> Ok(state)
            // The container is not a known tuple. The official compiler refuses
            // to index into a type it knows nothing about rather than
            // synthesising an arbitrary tuple arity, since the element at
            // `index` cannot be given a type without that knowledge.
            Error(_) ->
              Error(error.UnexpectedType(
                types.to_string(environment, tuple_type),
                "a tuple with an element at index " <> int.to_string(index),
              ))
          }
        }
      }
    }

    glance.List(_, elements, rest) ->
      list_expression(environment, store, elements, rest)

    glance.Fn(_, arguments, return_annotation, body) ->
      fn_literal(
        environment,
        store,
        arguments,
        return_annotation,
        body,
        expected,
      )

    glance.RecordUpdate(_, module, constructor, record, fields) ->
      record_update(environment, store, module, constructor, record, fields)

    glance.FieldAccess(_, container, label) -> {
      // Real Gleam resolves `name.label` by typing `name` as a value and
      // attempting record/field access first; only when the value has no such
      // field (or `name` is not bound as a value at all) does it fall back to
      // module access. A local `list: NonEmptyList` therefore shadows the
      // `gleam/list` import for `list.first`, while `dict.fold` on a `Dict`
      // value (no `fold` field) still resolves to the `gleam/dict` module.
      case expression(environment, store, container) {
        Ok(#(store, types.NamespaceType(nested_defs, _))) ->
          module_value(store, nested_defs, label)
        Ok(#(store, container_type)) ->
          case field_access_type(environment, store, container_type, label) {
            Ok(state) -> Ok(state)
            Error(record_error) ->
              case module_field_type(environment, store, container, label) {
                Ok(state) -> Ok(state)
                Error(_) ->
                  // Only defer to the second body pass once both record and
                  // module access have failed; an unbound container type
                  // (e.g. an inferred parameter) otherwise resolves to module
                  // access rather than being short-circuited.
                  case container_type {
                    types.Var(_) | types.InferredReturn ->
                      case environment.defer_unknown {
                        True -> Ok(#(store, types.InferredReturn))
                        False -> Error(record_error)
                      }
                    _ -> Error(record_error)
                  }
              }
          }
        Error(expression_error) ->
          case container {
            glance.Variable(_, _) ->
              module_field_type(environment, store, container, label)
            _ -> Error(expression_error)
          }
      }
    }

    glance.Call(_, target, arguments) ->
      call(environment, store, target, arguments)

    glance.BinaryOperator(_, operator, left, right) ->
      binop(environment, store, operator, left, right)

    glance.BitString(_, segments) -> {
      use #(store, _) <- result.try(
        list.try_fold(segments, #(store, Nil), fn(state, segment) {
          let #(store, _) = state
          let #(value_expr, options) = segment
          // The segment value type must be compatible with the options'
          // type family, sizes must be positive Ints, and conflicting options
          // are rejected.
          use #(store, _) <- result.try(bit_string_segment_value(
            environment,
            store,
            value_expr,
            options,
          ))
          // Sizes in options (and their expressions) must each typecheck.
          use store <- result.try(check_bit_string_sizes(
            environment,
            store,
            options,
          ))
          Ok(#(store, Nil))
        }),
      )
      Ok(#(store, types.BitArrayType))
    }

    glance.Case(_, subjects, clauses) ->
      case_expression(environment, store, subjects, clauses)

    glance.Echo(_, echoed, message) -> {
      // `echo` has the type of the printed expression, and both the printed
      // expression and the optional message must themselves typecheck.
      use #(store, echoed_type) <- result.try(case echoed {
        option.None -> Ok(#(store, types.NilType))
        option.Some(expr) -> expression(environment, store, expr)
      })
      use #(store, _) <- result.try(case message {
        option.None -> Ok(#(store, types.NilType))
        option.Some(message_expr) ->
          expression(environment, store, message_expr)
      })
      Ok(#(store, echoed_type))
    }

    glance.FnCapture(_, label, function, arguments_before, arguments_after) -> {
      use #(store, target_type) <- result.try(expression(
        environment,
        store,
        function,
      ))

      case target_type {
        types.CallableType(..) | types.GenericCallableType(..) -> {
          let #(store, parameters, labels, return) =
            types.instantiate_callable(store, target_type)

          // Typecheck the capture's arguments against the parameter positions
          // they consume, so anonymous function arguments get their expected
          // parameter type (and their bodies resolve) before the capture is
          // built.
          use #(store, typed_before, before_state) <- result.try(
            typecheck_capture_arguments(
              environment,
              store,
              parameters,
              labels,
              arguments_before,
              CaptureState(set.new(), [], 0),
            ),
          )

          let hole_position = case label {
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

          let with_hole =
            CaptureState(
              claimed: set.insert(before_state.claimed, hole_position),
              consumed: before_state.consumed,
              counter: before_state.counter,
            )

          use #(store, typed_after, _after_state) <- result.try(
            typecheck_capture_arguments(
              environment,
              store,
              parameters,
              labels,
              arguments_after,
              with_hole,
            ),
          )

          fn_capture(
            environment,
            store,
            parameters,
            labels,
            return,
            label,
            typed_before,
            typed_after,
          )
        }
        _ -> Error(error.NotCallable(types.to_string(environment, target_type)))
      }
    }
  }
}

/// Typecheck a list literal. All elements must unify to the same element type;
/// the rest (if present) must be a list of that same element type.
fn list_expression(
  environment: Environment,
  store: TypeStore,
  elements: List(glance.Expression),
  rest: option.Option(glance.Expression),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  use #(store, element_types) <- result.try(
    list.try_fold(elements, #(store, []), fn(state, element) {
      let #(store, reversed) = state
      expression(environment, store, element)
      |> result.map(fn(state) {
        let #(store, type_) = state
        #(store, [type_, ..reversed])
      })
    }),
  )
  let element_types = list.reverse(element_types)

  let element_type_result = case elements {
    [] -> {
      case rest {
        option.None -> {
          let #(store, element) = types.fresh_var(store)
          Ok(#(store, element))
        }
        option.Some(_) ->
          Error(error.InvalidType("unknown", "List", "empty list with rest"))
      }
    }
    [_, ..] ->
      case element_types {
        [first, ..rest_types] ->
          list.try_fold(rest_types, store, fn(store, element_type) {
            types.unify(store, environment, first, element_type)
          })
          |> result.map(fn(store) { #(store, first) })
        [] -> Error(error.InvalidType("unknown", "List", "empty element types"))
      }
  }

  use #(store, element_type) <- result.try(element_type_result)

  case rest {
    option.None ->
      Ok(#(
        store,
        types.CustomType("gleam", "List", [element_type], option.None),
      ))
    option.Some(rest_expr) -> {
      use #(store, rest_type) <- result.try(expression(
        environment,
        store,
        rest_expr,
      ))
      let #(store, rest_element) = case rest_type {
        types.CustomType("gleam", "List", [rest_element], option.None) -> #(
          store,
          rest_element,
        )
        _ -> {
          let #(store, rest_element) = types.fresh_var(store)
          #(store, rest_element)
        }
      }
      let mismatch = fn(_) {
        error.InvalidType(
          types.to_string(environment, rest_type),
          "List(" <> types.to_string(environment, element_type) <> ")",
          "list rest must be a list",
        )
      }
      types.unify(
        store,
        environment,
        rest_type,
        types.CustomType("gleam", "List", [rest_element], option.None),
      )
      |> result.map_error(mismatch)
      |> result.map(fn(store) {
        types.unify(store, environment, element_type, rest_element)
      })
      |> result.flatten
      |> result.map_error(mismatch)
      |> result.map(fn(store) {
        #(store, types.CustomType("gleam", "List", [element_type], option.None))
      })
    }
  }
}

/// Check that a function literal does not declare two parameters with the
/// same name.
fn check_duplicate_fn_parameter_names(
  arguments: List(glance.FnParameter),
) -> Result(Nil, error.TypeCheckError) {
  let counts =
    list.fold(arguments, dict.new(), fn(acc, param) {
      case param {
        glance.FnParameter(glance.Named(name), _) -> {
          let count = dict.get(acc, name) |> result.unwrap(0)
          dict.insert(acc, name, count + 1)
        }
        glance.FnParameter(glance.Discarded(_), _) -> acc
      }
    })
  case
    dict.filter(counts, fn(_name, count) { count > 1 })
    |> dict.keys
    |> list.first
  {
    Ok(name) -> Error(error.DuplicateArgumentName(name))
    Error(_) -> Ok(Nil)
  }
}

/// Typecheck a function literal. Parameters without annotations are inferred
/// from their use within the body.
/// When an `expected` type is supplied (a callable type from the call site),
/// unannotated parameters are bound to the corresponding expected parameter
/// types *before* the body is checked. This is what lets a callback's body
/// typecheck correctly when the parameter's type can only be learned from the
/// callee's signature — e.g. `result.map(expr, fn(x) { x.location })` where
/// `x` must be `Expression` for the field access to resolve. Annotated
/// parameters are left to the user's annotation; the whole lambda is unified
/// with the expected type by the call site afterwards. Generalisation happens
/// at binding boundaries, not on the lambda itself.
fn fn_literal(
  environment: Environment,
  store: TypeStore,
  arguments: List(glance.FnParameter),
  return_annotation: option.Option(glance.Type),
  body: List(glance.Statement),
  expected: option.Option(Type),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  // The parameter names of a function literal must be distinct.
  use _store <- result.try(check_duplicate_fn_parameter_names(arguments))

  use #(store, param_types) <- result.try(
    list.try_fold(arguments, #(store, []), fn(state, param) {
      let #(store, reversed) = state
      case param {
        glance.FnParameter(_, type_: option.Some(annotation)) ->
          types.type_with_store(environment, store, annotation)
          |> result.map(fn(state) {
            let #(store, type_) = state
            #(store, [type_, ..reversed])
          })
        glance.FnParameter(_, type_: option.None) -> {
          let #(store, type_) = types.fresh_var(store)
          Ok(#(store, [type_, ..reversed]))
        }
      }
    }),
  )
  let param_types = list.reverse(param_types)

  // Bind unannotated parameters to their expected types, in case this literal
  // is supplied where a concrete callable type is expected (e.g. as a callback
  // argument). Only unbinded inference variables are bound here; annotated and
  // explicitly-generic parameters keep their given types so the lambda may
  // remain polymorphic.
  use #(store, _) <- result.try(case expected {
    option.Some(expected_type) ->
      case expected_type {
        types.CallableType(expected_params, _, _)
        | types.GenericCallableType(expected_params, _, _, _) ->
          case list.length(param_types) == list.length(expected_params) {
            True ->
              list.try_fold(
                list.zip(param_types, expected_params),
                #(store, Nil),
                fn(state, pair) {
                  let #(store, _) = state
                  let #(param_type, expected_param) = pair
                  case param_type {
                    types.Var(_) ->
                      types.unify(
                        store,
                        environment,
                        param_type,
                        expected_param,
                      )
                    _ -> Ok(store)
                  }
                  |> result.map(fn(store) { #(store, Nil) })
                },
              )
              |> result.map(fn(state) { #(state.0, Nil) })
            False -> Ok(#(store, Nil))
          }
        _ -> Ok(#(store, Nil))
      }
    option.None -> Ok(#(store, Nil))
  })

  use #(store, param_env) <- result.try(
    list.try_fold(
      list.zip(arguments, param_types),
      #(store, environment),
      fn(state, pair) {
        let #(store, env) = state
        let #(param, type_) = pair
        case param {
          glance.FnParameter(glance.Named(name), _) ->
            Ok(#(store, types.add_or_update_def_in_env(env, name, type_)))
          glance.FnParameter(glance.Discarded(_), _) -> Ok(#(store, env))
        }
      },
    ),
  )

  use #(store, inferred_return) <- result.try(block(param_env, store, body))

  use #(store, return_type) <- result.try(case return_annotation {
    option.None -> Ok(#(store, inferred_return))
    option.Some(annotation) -> {
      use #(store, annotated) <- result.try(types.type_with_store(
        environment,
        store,
        annotation,
      ))
      case types.unify(store, environment, inferred_return, annotated) {
        Ok(store) -> {
          let #(_, resolved) = types.resolve(store, annotated)
          Ok(#(store, resolved))
        }
        Error(_) ->
          Error(error.InvalidReturnType(
            "anonymous function",
            types.to_string(environment, inferred_return),
            types.to_string(environment, annotated),
          ))
      }
    }
  })

  // Don't generalise here: unannotated parameters and the return type are
  // inference variables that should be bound by the expected type at the use
  // site. Generalisation happens at binding boundaries, not on the lambda
  // itself. Annotations may still introduce named generics, which keep the
  // lambda polymorphic.
  let lambda_type = case
    functions.has_generic_types(param_types)
    || functions.is_generic_type(return_type)
  {
    True ->
      types.GenericCallableType(
        param_types,
        dict.new(),
        return_type,
        functions.dummy_function(),
      )
    False -> types.CallableType(param_types, dict.new(), return_type)
  }

  Ok(#(store, lambda_type))
}

/// Resolve `name.label` as module access against `name`'s module namespace.
/// Only called as a fallback once field access on the value has failed.
fn module_field_type(
  environment: Environment,
  store: TypeStore,
  container: glance.Expression,
  label: String,
) -> error.TypeCheckResult(#(TypeStore, types.Type)) {
  case container {
    glance.Variable(_, name) ->
      case dict.get(environment.module_imports, name) {
        Ok(types.NamespaceType(nested_defs, _)) ->
          module_value(store, nested_defs, label)
        _ -> Error(error.InvalidName(name))
      }
    _ -> Error(error.InvalidFieldAccess("", label))
  }
}

fn module_value(
  store: TypeStore,
  nested_defs: dict.Dict(String, types.Type),
  label: String,
) -> error.TypeCheckResult(#(TypeStore, types.Type)) {
  nested_defs
  |> dict.get(label)
  |> result.replace_error(error.InvalidName(label))
  |> result.map(fn(type_) {
    let #(store, type_) = types.instantiate(store, type_)
    #(store, type_)
  })
}

/// The public definitions of another module in the package, so field access can
/// resolve constructors of types from modules that were not explicitly
/// imported.
fn module_definitions(
  environment: Environment,
  module: String,
) -> error.TypeCheckResult(dict.Dict(String, types.Type)) {
  case dict.get(environment.module_environments, module) {
    Ok(other_env) ->
      Ok(
        dict.filter(other_env.definitions, fn(name, _type_) {
          set.contains(other_env.public_definitions, name)
        }),
      )
    Error(_) -> Error(error.InvalidFieldAccess("", module))
  }
}

/// Typecheck a field access expression (`record.label`). The container must
/// be a custom type whose constructor has a parameter with the given label.
fn field_access_type(
  environment: Environment,
  store: TypeStore,
  container_type: types.Type,
  label: String,
) -> error.TypeCheckResult(#(TypeStore, types.Type)) {
  let #(store, container_type) = types.resolve(store, container_type)
  case container_type {
    types.CustomType(module, name, _parameters, inferred_variant) -> {
      let definitions_result = case module == environment.current_module {
        True -> Ok(environment.definitions)
        False -> {
          case dict.get(environment.import_names, module) {
            Ok(namespace) ->
              case dict.get(environment.module_imports, namespace) {
                Ok(types.NamespaceType(nested_defs, _)) -> Ok(nested_defs)
                _ -> module_definitions(environment, module)
              }
            _ -> module_definitions(environment, module)
          }
        }
      }

      use definitions <- result.try(definitions_result)

      // Collect every variant constructor of this type. A field may only be
      // accessed when it exists on *every* variant, and at the *same* position
      // in each: otherwise there is no single accessor that works for the whole
      // type. When the value has been refined to a single variant (via pattern
      // matching) only that constructor is considered.
      let #(store, constructors) =
        dict.fold(definitions, #(store, []), fn(state, _ctor_name, def) {
          let #(store, acc) = state
          case def {
            types.CallableType(..) | types.GenericCallableType(..) -> {
              let #(store, parameters, labels, return) =
                types.instantiate_callable(store, def)
              let is_target = case return {
                types.CustomType(return_module, return_name, _, return_variant) -> {
                  // Only genuine variant constructors (registered with a
                  // variant index) expose record fields. Plain functions
                  // that happen to return this custom type are not fields.
                  let is_constructor = case return_variant {
                    option.Some(_) -> True
                    option.None -> False
                  }
                  let variant_matches = case inferred_variant {
                    option.None -> True
                    option.Some(expected_index) ->
                      return_variant == option.Some(expected_index)
                  }
                  is_constructor
                  && return_module == module
                  && return_name == name
                  && variant_matches
                }
                _ -> False
              }
              case is_target {
                True -> #(store, [#(parameters, labels, return), ..acc])
                False -> #(store, acc)
              }
            }
            _ -> #(store, acc)
          }
        })

      case constructors {
        [] ->
          Error(error.InvalidFieldAccess(
            types.to_string(environment, container_type),
            label,
          ))
        [#(parameters, labels, return_type)] ->
          variant_field_type(
            environment,
            store,
            container_type,
            parameters,
            labels,
            return_type,
            label,
          )
        _ ->
          // Multiple variants: the label must be present on every variant and
          // at the same position, or no single accessor exists.
          case
            list.all(constructors, fn(entry) {
              let #(_, entry_labels, _) = entry
              dict.has_key(entry_labels, label)
            })
          {
            False ->
              Error(error.MissingField(
                types.to_string(environment, container_type)
                <> " does not have field "
                <> label
                <> " on every variant",
              ))
            True -> {
              let positions =
                list.map(constructors, fn(entry) {
                  let #(_, entry_labels, _) = entry
                  dict.get(entry_labels, label)
                  |> result.unwrap(-1)
                })
              case
                list.all(positions, fn(position) {
                  position == list.first(positions) |> result.unwrap(-1)
                })
              {
                False ->
                  Error(error.MissingField(
                    types.to_string(environment, container_type)
                    <> " has field "
                    <> label
                    <> " at different positions on its variants",
                  ))
                True ->
                  case list.first(constructors) {
                    Ok(#(parameters, labels, return_type)) ->
                      variant_field_type(
                        environment,
                        store,
                        container_type,
                        parameters,
                        labels,
                        return_type,
                        label,
                      )
                    Error(_) ->
                      Error(error.InvalidFieldAccess(
                        types.to_string(environment, container_type),
                        label,
                      ))
                  }
              }
            }
          }
      }
    }
    _ ->
      Error(error.InvalidFieldAccess(
        types.to_string(environment, container_type),
        label,
      ))
  }
}

fn variant_field_type(
  environment: Environment,
  store: TypeStore,
  container_type: types.Type,
  parameters: List(types.Type),
  labels: dict.Dict(String, Int),
  return_type: types.Type,
  label: String,
) -> error.TypeCheckResult(#(TypeStore, types.Type)) {
  // Unify the container with the constructor's return type so the field type
  // is expressed in terms of the container's actual type parameters (e.g.
  // `key.function` on `Decoder(key)` yields `key`, not a fresh var).
  use store <- result.try(types.unify(
    store,
    environment,
    container_type,
    return_type,
  ))

  dict.get(labels, label)
  |> result.map(fn(position) {
    let expected_type =
      list.drop(parameters, up_to: position)
      |> list.first
      |> result.unwrap(types.GenericTypeVariable("todo"))
    let #(_, expected_type) = types.resolve(store, expected_type)
    #(store, expected_type)
  })
  |> result.map_error(fn(_) {
    error.InvalidFieldAccess(
      types.to_string(environment, container_type),
      label,
    )
  })
}

/// Typecheck a record update expression (`Type(..record, field: value)`).
/// The record must already be bound to a variable of the custom type.
fn record_update(
  environment: Environment,
  store: TypeStore,
  module: option.Option(String),
  constructor: String,
  record: glance.Expression,
  fields: List(glance.RecordUpdateField(glance.Expression)),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  use #(store, record_type) <- result.try(expression(environment, store, record))

  let constructor_lookup = case module {
    option.None ->
      dict.get(environment.definitions, constructor)
      |> result.replace_error(error.InvalidName(constructor))
    option.Some(module_name) -> {
      case dict.get(environment.module_imports, module_name) {
        Ok(types.NamespaceType(nested_defs, _)) ->
          dict.get(nested_defs, constructor)
          |> result.replace_error(error.InvalidName(constructor))
        _ -> Error(error.InvalidName(constructor))
      }
    }
  }

  use constructor_type <- result.try(constructor_lookup)

  // Updating the same field more than once is an error.
  use _ <- result.try(check_update_no_duplicate_fields(fields))

  // The updated value's variant must be statically known and match the
  // constructor. Reject updates on an open/multi-variant value, on a
  // cross-variant update, on a type-parameter that would change, and on a
  // type parameter shared with another field being left un-updated.
  use _ <- result.try(check_update_variant_safety(
    environment,
    store,
    constructor,
    record_type,
  ))
  use _ <- result.try(check_update_linked_field(
    environment,
    constructor_type,
    constructor,
    fields,
  ))

  case constructor_type {
    types.CallableType(..) | types.GenericCallableType(..) -> {
      let #(store, parameters, labels, constructor_return) =
        types.instantiate_callable(store, constructor_type)

      let #(store, _, _, record_check_return) =
        types.instantiate_callable(store, constructor_type)

      use store <- result.try(types.unify(
        store,
        environment,
        record_type,
        record_check_return,
      ))

      list.try_fold(fields, #(store, environment), fn(state, field) {
        let #(store, env) = state
        dict.get(labels, field.label)
        |> result.map_error(fn(_) {
          error.InvalidFieldAccess(
            types.to_string(env, record_type),
            field.label,
          )
        })
        |> result.try(fn(position) {
          let expected_type =
            list.drop(parameters, up_to: position)
            |> list.first
            |> result.unwrap(types.GenericTypeVariable("todo"))
          let #(_, expected_type) = types.resolve(store, expected_type)
          case field.item {
            option.None -> Ok(#(store, env))
            option.Some(value_expr) -> {
              use #(store, value_type) <- result.try(expression(
                env,
                store,
                value_expr,
              ))
              types.unify(store, env, value_type, expected_type)
              |> result.map(fn(store) { #(store, env) })
              |> result.map_error(fn(_) {
                error.InvalidType(
                  types.to_string(env, value_type),
                  types.to_string(env, expected_type),
                  "in record update of field " <> field.label,
                )
              })
            }
          }
        })
      })
      |> result.map(fn(state) {
        let #(store, _env) = state
        #(store, constructor_return)
      })
    }
    _ ->
      Error(error.NotCallable(types.to_string(environment, constructor_type)))
  }
}

/// A record update is unsafe if updating one field forces a type parameter to
/// change while another field that shares the same type parameter is left
/// un-updated. This mirrors the official compiler's "if the same type variable
/// is used for multiple fields, all those fields need to be updated".
fn check_update_linked_field(
  environment: Environment,
  constructor_type: Type,
  constructor: String,
  fields: List(glance.RecordUpdateField(glance.Expression)),
) -> error.TypeCheckResult(Environment) {
  let params_and_labels = case constructor_type {
    types.CallableType(parameters, labels, _) -> #(parameters, labels)
    types.GenericCallableType(parameters, labels, _, _) -> #(parameters, labels)
    _ -> #([], dict.new())
  }
  let #(parameters, labels) = params_and_labels

  let updated_positions =
    fields
    |> list.filter_map(fn(field) { dict.get(labels, field.label) })

  // Map each generic type variable name to its number of positions and how many
  // of those are updated. If a variable appears at several positions and the
  // update touches only some of them, the others' types would change implicitly.
  let unsafe =
    parameters
    |> list.index_map(fn(param, index) {
      let updated = list.contains(updated_positions, index)
      case param {
        types.GenericTypeVariable(_) -> option.Some(#(param, updated))
        _ -> option.None
      }
    })
    // positions shared by more than one field: same generic name different
    // positions
    |> list.fold(dict.new(), fn(acc, entry) {
      case entry {
        option.None -> acc
        option.Some(#(param, updated)) ->
          dict.upsert(acc, param, fn(existing) {
            let #(total, updated_total) = option.unwrap(existing, #(0, 0))
            let updated_total = case updated {
              True -> updated_total + 1
              False -> updated_total
            }
            #(total + 1, updated_total)
          })
      }
    })
    |> dict.values
    |> list.any(fn(pair) {
      let #(total, updated_total) = pair
      total > 1 && updated_total > 0 && updated_total < total
    })

  case unsafe {
    True -> Error(error.UnsafeRecordUpdate(constructor))
    False -> Ok(environment)
  }
}

/// Duplicate field labels within a single record update are an error.
fn check_update_no_duplicate_fields(
  fields: List(glance.RecordUpdateField(glance.Expression)),
) -> Result(Nil, error.TypeCheckError) {
  let relevant = fields |> list.map(fn(field) { field.label })
  let #(_seen, duplicate) =
    list.fold(relevant, #(set.new(), option.None), fn(state, label) {
      let #(seen, found) = state
      case found {
        option.Some(_) -> state
        option.None ->
          case set.contains(seen, label) {
            True -> #(seen, option.Some(label))
            False -> #(set.insert(seen, label), option.None)
          }
      }
    })
  case duplicate {
    option.Some(label) -> Error(error.DuplicateArgument(label))
    option.None -> Ok(Nil)
  }
}

/// A `..` record update is only safe when the spread value is statically known
/// to be the same single variant being constructed. This rejects (a) updating
/// a value whose type pins no variant because the type has several, (b)
/// updating a value known to be a different variant, and (c) updating a type
/// parameter on a polymorphic value.
fn check_update_variant_safety(
  environment: Environment,
  store: TypeStore,
  constructor: String,
  record_type: Type,
) -> error.TypeCheckResult(TypeStore) {
  let #(store, resolved) = types.resolve(store, record_type)
  case resolved {
    types.CustomType(module, name, _parameters, inferred_variant) -> {
      // How many variants the custom type has, and which variant the update's
      // constructor targets. A type defined in this module is looked up by its
      // unqualified constructor; only imported types need the module qualifier.
      let variant_count = custom_type_variant_count(environment, module, name)
      let constructor_module = case module == environment.current_module {
        True -> option.None
        False -> option.Some(module)
      }
      let constructor_variant =
        pattern.constructor_variant_index(
          environment,
          constructor_module,
          constructor,
        )

      case variant_count {
        // A single-variant type is always safe to update.
        1 -> Ok(store)
        _ -> {
          case inferred_variant {
            // Variant not pinned: we don't know which one we have.
            option.None -> Error(error.UnsafeRecordUpdate(constructor))
            option.Some(index) ->
              case constructor_variant == option.Some(index) {
                True -> Ok(store)
                False -> Error(error.UnsafeRecordUpdate(constructor))
              }
          }
        }
      }
    }
    _ -> Ok(store)
  }
}

/// Count how many variants a custom type (module, name) has by scanning the
/// environment's stored values for constructors whose return type is that
/// custom type with a pinned variant index. Not needed for correctness of
/// single-variant logic; bounded length of a useful list of variants is grand.
fn custom_type_variant_count(
  environment: Environment,
  module_name: String,
  name: String,
) -> Int {
  let source = case module_name {
    "." -> environment.current_module
    other -> types.module_access_name(environment, other)
  }
  let definitions = case source == environment.current_module {
    True -> environment.definitions
    False ->
      case dict.get(environment.module_imports, source) {
        Ok(types.NamespaceType(defs, _custom_types)) -> defs
        _ -> environment.definitions
      }
  }
  let our = fn(type_) -> option.Option(Int) {
    case type_ {
      types.CustomType(m, n, _, variant)
        if n == name && { m == module_name || m == source }
      -> variant
      _ -> option.None
    }
  }
  definitions
  |> dict.values
  |> list.fold(set.new(), fn(seen, type_) {
    let candidate = case type_ {
      types.CallableType(_, _, return_) -> our(return_)
      types.GenericCallableType(_, _, return_, _) -> our(return_)
      _ -> option.None
    }
    case candidate {
      option.Some(index) -> set.insert(seen, index)
      option.None -> seen
    }
  })
  |> set.size
}

/// Typecheck a single bit-string segment. The segment value's type must match
/// the type family chosen by the options, and the segment's size/unit options
/// must be valid positive sizes.
fn bit_string_segment_value(
  environment: Environment,
  store: TypeStore,
  value_expr: glance.Expression,
  options: List(glance.BitStringSegmentOption(glance.Expression)),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  use #(store, value_type) <- result.try(expression(
    environment,
    store,
    value_expr,
  ))
  let expected_family = case bit_string_segment.segment_type(options) {
    types.IntType ->
      case value_expr {
        glance.String(_, _) -> types.StringType
        glance.Float(_, _) -> types.FloatType
        _ -> types.IntType
      }
    forced_family -> forced_family
  }
  types.unify(store, environment, value_type, expected_family)
  |> result.map(fn(store) { #(store, value_type) })
  |> result.map_error(fn(_) {
    error.InvalidType(
      types.to_string(environment, value_type),
      types.to_string(environment, expected_family),
      "in bit string segment",
    )
  })
}

/// Validate every size/unit option in a segment: size expressions must
/// typecheck to Int, literal sizes and units must be positive, and options
/// that conflict (e.g. two different sizes or units) are rejected.
fn check_bit_string_sizes(
  environment: Environment,
  store: TypeStore,
  options: List(glance.BitStringSegmentOption(glance.Expression)),
) -> error.TypeCheckResult(TypeStore) {
  use store <- result.try(check_option_conflicts(environment, store, options))
  check_literal_sizes(environment, store, options)
}

/// Reject segments that declare mutually exclusive options: more than one
/// size/unit, or a signedness/endianness clash. Returns the environment on
/// success.
fn check_option_conflicts(
  _environment: Environment,
  store: TypeStore,
  options: List(glance.BitStringSegmentOption(glance.Expression)),
) -> error.TypeCheckResult(TypeStore) {
  let size_count =
    list.count(options, fn(o) {
      case o {
        glance.SizeOption(_) | glance.SizeValueOption(_) -> True
        _ -> False
      }
    })
  let unit_count =
    list.count(options, fn(o) {
      case o {
        glance.UnitOption(_) -> True
        _ -> False
      }
    })
  let conflict = size_count > 1 || unit_count > 1

  case conflict {
    True -> Error(error.InvalidBitStringSegment("size"))
    False -> Ok(store)
  }
}

/// Static literal sizes and units must be positive; size expressions must
/// typecheck to Int.
fn check_literal_sizes(
  environment: Environment,
  store: TypeStore,
  options: List(glance.BitStringSegmentOption(glance.Expression)),
) -> error.TypeCheckResult(TypeStore) {
  list.try_fold(options, store, fn(store, option) {
    case option {
      glance.SizeOption(size) if size <= 0 ->
        Error(error.InvalidBitStringSegment("size"))
      glance.UnitOption(unit) if unit <= 0 ->
        Error(error.InvalidBitStringSegment("unit"))
      glance.SizeValueOption(size_expr) ->
        check_size_expression(environment, store, size_expr)
      _ -> Ok(store)
    }
  })
}

/// A size expression must typecheck and have type Int.
fn check_size_expression(
  environment: Environment,
  store: TypeStore,
  size_expr: glance.Expression,
) -> error.TypeCheckResult(TypeStore) {
  use #(store, size_type) <- result.try(expression(
    environment,
    store,
    size_expr,
  ))
  types.unify(store, environment, size_type, types.IntType)
  |> result.map(fn(store) { store })
  |> result.map_error(fn(_) { error.InvalidBitStringSegment("size") })
}

/// Typecheck a case expression. Each clause's patterns must match the subject
/// types, guards must be Bool, and all clause bodies must unify to the same
/// type, which is the type of the whole expression.
fn case_expression(
  environment: Environment,
  store: TypeStore,
  subjects: List(glance.Expression),
  clauses: List(glance.Clause),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  use #(store, subject_types) <- result.try(
    list.try_fold(subjects, #(store, []), fn(state, subject) {
      let #(store, reversed) = state
      expression(environment, store, subject)
      |> result.map(fn(state) {
        let #(store, type_) = state
        #(store, [type_, ..reversed])
      })
    }),
  )
  let subject_types = list.reverse(subject_types)
  let subject_names =
    list.map(subjects, fn(subject) {
      case subject {
        glance.Variable(_, name) -> option.Some(name)
        _ -> option.None
      }
    })

  use _ <- result.try(
    list.try_fold(clauses, Nil, fn(_, clause) {
      validate_clause_patterns(clause, list.length(subjects))
    }),
  )

  case clauses {
    [] ->
      case
        exhaustive.check(
          environment,
          resolve_subjects(store, subject_types),
          [],
        )
      {
        option.Some(missing) ->
          Error(error.InexhaustivePattern(string.join(missing, "\n")))
        option.None -> Error(error.CaseClauseMismatch("no clauses", "any"))
      }
    [_first_clause, ..] -> {
      // Typecheck each clause body sequentially, threading the store so each
      // clause gets a distinct namespace of inference variables. Unifying the
      // bodies afterwards then cannot conflate vars that belong to different
      // clauses.
      let checked = {
        use #(store, clause_types) <- result.try(
          list.try_fold(clauses, #(store, []), fn(state, clause) {
            let #(store, reversed) = state
            clause_body_type(
              environment,
              store,
              subject_types,
              subject_names,
              clause,
            )
            |> result.map(fn(state) {
              let #(store, type_) = state
              #(store, [type_, ..reversed])
            })
          }),
        )
        let clause_types = list.reverse(clause_types)

        case clause_types {
          [] -> Error(error.CaseClauseMismatch("no clauses", "any"))
          [first_body_type, ..remaining_types] ->
            list.try_fold(remaining_types, store, fn(store, clause_type) {
              types.unify(store, environment, first_body_type, clause_type)
            })
            |> result.map(fn(store) {
              // Prefer a concrete clause type over the `todo`/`InferredReturn`
              // wildcards, which unify with anything without pinning a type
              // (e.g. `case .. { _ -> panic; _ -> value }` must infer the
              // value's type).
              let case_type =
                [first_body_type, ..remaining_types]
                |> list.find(fn(type_) {
                  case type_ {
                    types.GenericTypeVariable("todo") | types.InferredReturn ->
                      False
                    _ -> True
                  }
                })
                |> result.unwrap(types.GenericTypeVariable("todo"))
              #(store, case_type)
            })
        }
      }

      // The clause bodies have now typechecked; reject a case that does not
      // cover every possible value of the subjects, matching the official
      // compiler's inexhaustive pattern check. Each clause may have several
      // or-alternatives; the case is exhaustive only when all alternatives
      // together cover every value. A guarded clause only matches when its
      // guard passes, so it never guarantees coverage on its own.
      let alternatives =
        clauses
        |> list.filter(fn(clause) {
          case clause.guard {
            option.None -> True
            option.Some(_) -> False
          }
        })
        |> list.map(fn(clause) { clause.patterns })
        |> list.flatten
      case checked {
        Error(check_error) -> Error(check_error)
        Ok(case_state) -> {
          let #(store, _case_type) = case_state
          case
            exhaustive.check(
              environment,
              resolve_subjects(store, subject_types),
              alternatives,
            )
          {
            option.Some(missing) ->
              Error(error.InexhaustivePattern(string.join(missing, "\n")))
            option.None -> Ok(case_state)
          }
        }
      }
    }
  }
}

/// The variables bound by a pattern, each with the path (per-subject index
/// followed by nested field indices) of the binding site. Used to validate
/// duplicate and alternative-consistency rules for clause patterns.
fn pattern_bound_variables(
  prefix: List(Int),
  pattern: glance.Pattern,
) -> List(#(String, List(Int))) {
  case pattern {
    glance.PatternVariable(_, name) -> [#(name, prefix)]
    glance.PatternDiscard(_, _) -> []
    glance.PatternAssignment(_, inner, name) -> [
      #(name, prefix),
      ..pattern_bound_variables(prefix, inner)
    ]
    glance.PatternInt(_, _)
    | glance.PatternFloat(_, _)
    | glance.PatternString(_, _)
    | glance.PatternBitString(_, _) -> []
    glance.PatternConcatenate(_, _, prefix_name, rest_name) -> {
      let prefix_vars = case prefix_name {
        option.Some(glance.Named(name)) -> [#(name, prefix)]
        option.Some(glance.Discarded(_)) | option.None -> []
      }
      let rest_vars = case rest_name {
        glance.Named(name) -> [#(name, prefix)]
        glance.Discarded(_) -> []
      }
      list.append(prefix_vars, rest_vars)
    }
    glance.PatternTuple(_, elements) ->
      elements
      |> list.index_map(fn(element, index) {
        pattern_bound_variables([index, ..prefix], element)
      })
      |> list.flatten
    glance.PatternList(_, elements, tail) -> {
      let element_vars =
        elements
        |> list.index_map(fn(element, index) {
          pattern_bound_variables([index, ..prefix], element)
        })
        |> list.flatten
      let tail_vars = case tail {
        option.Some(tail_pattern) ->
          pattern_bound_variables([1, ..prefix], tail_pattern)
        option.None -> []
      }
      list.append(element_vars, tail_vars)
    }
    glance.PatternVariant(_, _, _, arguments, _) ->
      arguments
      |> list.index_map(fn(field, index) {
        case field {
          glance.UnlabelledField(inner) ->
            pattern_bound_variables([index, ..prefix], inner)
          glance.LabelledField(_, _, inner) ->
            pattern_bound_variables([index, ..prefix], inner)
          glance.ShorthandField(label, _) -> [#(label, [index, ..prefix])]
        }
      })
      |> list.flatten
  }
}

/// Check that a clause's alternatives each have as many patterns as the case
/// has subjects, that no alternative binds a variable twice, and that the
/// alternatives bind the same variables at the same positions.
fn validate_clause_patterns(
  clause: glance.Clause,
  subject_count: Int,
) -> Result(Nil, error.TypeCheckError) {
  case clause.patterns {
    [] -> Ok(Nil)
    [first, ..rest] -> {
      use first_vars <- result.try(validate_alternative_patterns(
        first,
        subject_count,
      ))
      list.try_fold(rest, Nil, fn(_, alternative) {
        use alternative_vars <- result.try(validate_alternative_patterns(
          alternative,
          subject_count,
        ))
        validate_alternative_consistency(first_vars, alternative_vars)
      })
    }
  }
}

fn validate_alternative_patterns(
  patterns: List(glance.Pattern),
  subject_count: Int,
) -> Result(List(#(String, List(Int))), error.TypeCheckError) {
  case list.length(patterns) == subject_count {
    False ->
      Error(error.IncorrectPatternCount(list.length(patterns), subject_count))
    True -> {
      let variables =
        patterns
        |> list.index_map(fn(pattern, subject) {
          pattern_bound_variables([subject], pattern)
        })
        |> list.flatten
      list.try_fold(variables, [], fn(acc, variable) {
        let #(name, path) = variable
        case
          list.any(acc, fn(seen) {
            let #(seen_name, seen_path) = seen
            name == seen_name && path != seen_path
          })
        {
          True -> Error(error.DuplicatePatternVariable(name))
          False -> Ok([variable, ..acc])
        }
      })
    }
  }
}

/// A variable bound by the alternatives of a clause must be bound by every
/// alternative. The binding positions may differ between alternatives (e.g.
/// `[], list | list, []`); type agreement across alternatives is checked when
/// the alternatives are typechecked.
fn validate_alternative_consistency(
  first: List(#(String, List(Int))),
  other: List(#(String, List(Int))),
) -> Result(Nil, error.TypeCheckError) {
  case first {
    [] ->
      case other {
        [] -> Ok(Nil)
        [#(name, _), ..] -> Error(error.ExtraPatternVariable(name))
      }
    [#(name, _), ..rest] -> {
      case
        list.find(other, fn(seen) {
          let #(seen_name, _) = seen
          seen_name == name
        })
      {
        Error(_) -> Error(error.MissingPatternVariable(name))
        Ok(_) ->
          validate_alternative_consistency(
            rest,
            list.filter(other, fn(seen) {
              let #(seen_name, _) = seen
              seen_name != name
            }),
          )
      }
    }
  }
}

/// A `let` (or `let assert`) pattern may not bind the same variable twice.
fn validate_let_pattern_variables(
  pattern: glance.Pattern,
) -> Result(Nil, error.TypeCheckError) {
  let variables = pattern_bound_variables([0], pattern)
  case
    list.any(variables, fn(variable) {
      let #(name, path) = variable
      list.any(variables, fn(other) {
        let #(other_name, other_path) = other
        other_name == name && other_path != path
      })
    })
  {
    True ->
      case variables {
        [#(name, _), ..] -> Error(error.DuplicatePatternVariable(name))
        [] -> Ok(Nil)
      }
    False -> Ok(Nil)
  }
}

fn clause_body_type(
  environment: Environment,
  store: TypeStore,
  subject_types: List(Type),
  subject_names: List(Option(String)),
  clause: glance.Clause,
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  // `clause.patterns` is a list of OR-alternatives, each a list of patterns
  // aligned with the subjects. Typecheck every alternative against the base
  // environment so bindings from one alternative don't leak into another.
  //
  // A constructor pattern matching a subject that is a variable refines that
  // variable's type to a specific variant, so field access on it resolves the
  // correct field types. When OR-alternatives refine the same variable to
  // different variants the inference must be cleared (the variable has no
  // single known variant in the clause body).
  use #(store, alternatives) <- result.try(
    list.try_fold(clause.patterns, #(store, []), fn(state, alternative) {
      let #(store, acc) = state
      list.try_fold(
        list.zip(list.zip(subject_types, subject_names), alternative),
        #(store, environment, dict.new()),
        fn(state, pair) {
          let #(store, env, refinements) = state
          let #(subject_type, subject_name, pattern) = case pair {
            #(#(type_, name), pat) -> #(type_, name, pat)
          }
          use #(store, env) <- result.try(pattern.typecheck_pattern(
            env,
            store,
            subject_type,
            pattern,
          ))
          let refinements = case subject_name, pattern {
            option.Some(name),
              glance.PatternVariant(_, module, constructor, _arguments, _spread)
            ->
              // A variant refinement marks the subject variable as a known
              // variant so field access resolves the correct constructor's
              // field types. But if the pattern itself rebinds a variable with
              // the same name as the subject (e.g. `case state { Http2(state)
              // }`), the name now refers to the constructor field value's own
              // type, not the subject's. Applying a variant index to it would
              // stamp the *outer* constructor's index onto an unrelated type,
              // so skip the refinement in that case.
              case pattern.pattern_binds_name(pattern, name) {
                True -> refinements
                False ->
                  pattern.constructor_variant_index(env, module, constructor)
                  |> option.map(fn(index) {
                    dict.insert(refinements, name, index)
                  })
                  |> option.unwrap(refinements)
              }
            _, _ -> refinements
          }
          Ok(#(store, env, refinements))
        },
      )
      |> result.map(fn(state) {
        let #(store, env, refinements) = state
        #(store, [#(env, refinements), ..acc])
      })
    }),
  )
  let alternatives = list.reverse(alternatives)

  // The pattern environment for the body is the last alternative's. The
  // variant refinements that survive are those every alternative agrees on
  // (or that later alternatives never contradict).
  let #(pattern_env, agreed) = case alternatives {
    [] -> #(environment, dict.new())
    [first, ..rest] -> {
      let #(pattern_env, first_refinements) = first
      let agreed =
        list.fold(rest, first_refinements, fn(agreed, pair) {
          let #(_env, refinements) = pair
          dict.fold(refinements, agreed, fn(agreed, name, index) {
            case dict.get(agreed, name) {
              Ok(same_index) if same_index == index -> agreed
              _ -> dict.delete(agreed, name)
            }
          })
        })
      #(pattern_env, agreed)
    }
  }

  let #(store, pattern_env) =
    list.fold(
      dict.to_list(agreed),
      #(store, pattern_env),
      fn(state, name_and_index) {
        let #(store, environment) = state
        let #(name, index) = name_and_index
        apply_variant_refinement(store, environment, name, index)
      },
    )

  // Every alternative binds the same variables (checked syntactically), and
  // each binding must have the same type across alternatives, since the body
  // sees a single binding per name. A name bound to different types in
  // different alternatives (e.g. `#(x, _) | #(_, x)`) is a type error.
  use store <- result.try(
    list.try_fold(alternatives, store, fn(store, alternative) {
      let #(alternative_env, _refinements) = alternative
      dict.fold(
        alternative_env.definitions,
        Ok(store),
        fn(result, name, alternative_type) {
          use store <- result.try(result)
          case dict.get(pattern_env.definitions, name) {
            Ok(body_type) ->
              types.unify(store, pattern_env, alternative_type, body_type)
            Error(_) -> Ok(store)
          }
        },
      )
    }),
  )

  use #(store, guard_type) <- result.try(case clause.guard {
    option.None -> Ok(#(store, types.BoolType))
    option.Some(guard_expr) -> {
      check_guard_grammar(guard_expr)
      |> result.try(fn(_) { expression(pattern_env, store, guard_expr) })
    }
  })

  case types.unify(store, pattern_env, guard_type, types.BoolType) {
    Ok(store) -> expression(pattern_env, store, clause.body)
    Error(_) ->
      Error(error.InvalidGuard(types.to_string(pattern_env, guard_type)))
  }
}

/// The official compiler restricts case clause guards to a small grammar:
/// variables, field access, tuple indexes, negation, binary operators, blocks,
/// and constant values (literals, tuples, lists, record construction). Function
/// calls, pipelines, `case`, `panic`, `fn`, captures, record updates, and
/// assignments inside guards are rejected at parse time. Glance parses guards
/// as full expressions, so this check recovers that restriction.
fn check_guard_grammar(expr: glance.Expression) -> error.TypeCheckResult(Nil) {
  case expr {
    glance.Int(_, _) | glance.Float(_, _) | glance.String(_, _) -> Ok(Nil)
    glance.Variable(_, _) -> Ok(Nil)
    glance.Tuple(_, elements) -> check_guard_expressions(elements)
    glance.List(_, elements, rest) ->
      check_guard_expressions(elements)
      |> result.try(fn(_) {
        case rest {
          option.None -> Ok(Nil)
          option.Some(tail) -> check_guard_grammar(tail)
        }
      })
    glance.FieldAccess(_, container, _label) -> check_guard_grammar(container)
    glance.TupleIndex(_, tuple, _index) -> check_guard_grammar(tuple)
    glance.NegateBool(_, value) -> check_guard_grammar(value)
    // A `-` only appears before a literal (lexed as a single negative token by
    // the official compiler); negation of a non-literal is not valid in guards.
    glance.NegateInt(_, value) ->
      case value {
        glance.Int(_, _) | glance.Float(_, _) -> Ok(Nil)
        _ -> Error(error.InvalidGuardExpression)
      }
    glance.Block(_, statements) -> check_guard_block(statements)
    glance.BinaryOperator(_, operator, left, right) ->
      case operator {
        glance.Pipe -> Error(error.InvalidGuardExpression)
        _ ->
          check_guard_grammar(left)
          |> result.try(fn(_) { check_guard_grammar(right) })
      }
    glance.Call(_, function, arguments) -> {
      case is_record_construction(function) {
        True -> check_guard_arguments(arguments)
        False -> Error(error.InvalidGuardExpression)
      }
    }
    // Bit arrays are constant values, so they are permitted grammatically.
    glance.BitString(_, _segments) -> Ok(Nil)
    glance.Todo(_, _) -> Error(error.TodoInConstant)
    _ -> Error(error.InvalidGuardExpression)
  }
}

fn check_guard_expressions(
  expressions: List(glance.Expression),
) -> error.TypeCheckResult(Nil) {
  list.try_fold(expressions, Nil, fn(_nil, expr) { check_guard_grammar(expr) })
}

fn check_guard_arguments(
  arguments: List(glance.Field(glance.Expression)),
) -> error.TypeCheckResult(Nil) {
  list.try_fold(arguments, Nil, fn(_nil, field) {
    case field {
      glance.LabelledField(_label, _location, item) -> check_guard_grammar(item)
      glance.ShorthandField(_label, _location) -> Ok(Nil)
      glance.UnlabelledField(item) -> check_guard_grammar(item)
    }
  })
}

fn check_guard_block(
  statements: List(glance.Statement),
) -> error.TypeCheckResult(Nil) {
  list.try_fold(statements, Nil, fn(_nil, statement) {
    case statement {
      glance.Expression(expr) -> check_guard_grammar(expr)
      _ -> Error(error.InvalidGuardExpression)
    }
  })
}

/// Whether a call target is a record construction (`UpName(...)` or
/// `module.UpName(...)`), the only calls the official guard grammar permits.
fn is_record_construction(function: glance.Expression) -> Bool {
  case function {
    glance.Variable(_, name) -> is_upper_first(name)
    glance.FieldAccess(_, glance.Variable(_, _module), label) ->
      is_upper_first(label)
    _ -> False
  }
}

fn is_upper_first(name: String) -> Bool {
  string.first(name)
  |> result.map(fn(first) { string.uppercase(first) == first })
  |> result.unwrap(False)
}

/// Replace a subject variable's binding with a copy marked as a known variant,
/// so field access on it uses the matching constructor's field types.
fn apply_variant_refinement(
  store: TypeStore,
  environment: Environment,
  name: String,
  variant_index: Int,
) -> #(TypeStore, Environment) {
  case dict.get(environment.definitions, name) {
    Ok(type_) -> {
      // The binding may still be an unlinked variable that only resolves to
      // the concrete custom type through the store (e.g. a case subject bound
      // to a fresh variable by an earlier clause). Resolve it first so the
      // variant can be pinned on the concrete type, not lost on the variable.
      let #(store, resolved) = types.resolve(store, type_)
      let refined = types.set_custom_type_variant(resolved, variant_index)
      #(
        store,
        Environment(
          ..environment,
          definitions: dict.insert(environment.definitions, name, refined),
        ),
      )
    }
    Error(_) -> #(store, environment)
  }
}

/// Typecheck a function call. The target is typechecked and instantiated (so
/// generic parameters become fresh variables), then each argument is checked
/// against — and unified with — its parameter type *in parameter order*.
///
/// Checking arguments in parameter order (rather than typechecking them all
/// first and unifying afterwards) is what lets a callback supplied later in
/// the argument list learn parameter types that were constrained by earlier
/// arguments (e.g. `result.map(expr, fn(x) { ...})` where `x`'s type is only
/// determined once `expr` has fixed the generic). Anonymous function
/// arguments are typechecked with the expected parameter type, so their
/// parameters are bound to concrete types before the body is checked.
pub fn call(
  environment: Environment,
  store: TypeStore,
  target: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  use #(store, glimpse_target) <- result.try(expression(
    environment,
    store,
    target,
  ))

  use #(store, parameters, labels, return) <- result.try(callable_parts(
    environment,
    store,
    glimpse_target,
    list.length(arguments),
  ))

  use #(store, _argument_types) <- result.try(check_arguments(
    environment,
    store,
    arguments,
    parameters,
    labels,
  ))

  // While a same-module callee's signature is still a placeholder, record how
  // its generic parameters are constrained by the arguments, so a cycle across
  // functions is reported as a recursive type. The call's return is replaced
  // with a fresh variable tagged with the callee's return name, so a caller
  // whose own return embeds it is detected as infinitely recursive.
  use #(store, return) <- result.try(case target {
    glance.Variable(_, callee) -> {
      let constraints = {
        record_generic_constraints(environment, store, callee, arguments)
      }
      constraints
      |> result.map(fn(store) {
        case placeholder_callee(environment, callee) {
          True -> types.fresh_var_with_source(store, "r_" <> callee)
          False -> #(store, return)
        }
      })
    }
    _ -> Ok(#(store, return))
  })

  Ok(types.resolve(store, return))
}

/// Record how a same-module callee's generic parameters are constrained by the
/// arguments at this call site, so a cycle of embedding constraints across
/// functions is reported as a recursive type.
fn record_generic_constraints(
  environment: Environment,
  store: TypeStore,
  callee: String,
  arguments: List(glance.Field(glance.Expression)),
) -> Result(TypeStore, error.TypeCheckError) {
  case dict.get(environment.definitions, callee) {
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
fn argument_named_vars(
  environment: Environment,
  store: TypeStore,
  argument: glance.Expression,
) -> List(String) {
  case argument {
    glance.Variable(_, name) ->
      case dict.get(environment.definitions, name) {
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

fn placeholder_callee(environment: Environment, callee: String) -> Bool {
  case dict.get(environment.definitions, callee) {
    Ok(types.GenericCallableType(_, _, return_, _)) ->
      is_placeholder_return(return_)
    _ -> False
  }
}

fn is_placeholder_return(type_: Type) -> Bool {
  case type_ {
    types.InferredReturn -> True
    types.GenericTypeVariable("todo") -> True
    _ -> False
  }
}

/// Type-check call arguments against their parameter types.
///
/// Arguments are aligned to parameters (by label for labelled/shorthand
/// fields, positionally otherwise) and checked in *parameter* order so that
/// earlier arguments can constrain generic parameters that later, callback
/// arguments depend on. Anonymous function arguments are typechecked with the
/// expected parameter type so their bodies resolve; other arguments are
/// typechecked without an expected type (matching previous behaviour) and
/// then unified with their parameter.
fn check_arguments(
  environment: Environment,
  store: TypeStore,
  fields: List(glance.Field(glance.Expression)),
  parameters: List(Type),
  position_labels: dict.Dict(String, Int),
) -> error.TypeCheckResult(#(TypeStore, List(Type))) {
  let param_count = list.length(parameters)

  // Shorthand fields (`f(label:)`) reference a variable in scope. Resolve those
  // first so an `InvalidName` is reported before label/argument errors, matching
  // the previous behaviour where argument fields were fully typechecked before
  // argument ordering was performed.
  use #(store, shorthand_types) <- result.try(
    list.try_fold(fields, #(store, dict.new()), fn(state, field) {
      let #(store, acc) = state
      case field {
        glance.ShorthandField(label, _) ->
          types.lookup_variable_type(environment, label)
          |> result.try(fn(type_) {
            Ok(#(store, dict.insert(acc, label, type_)))
          })
        _ -> Ok(#(store, acc))
      }
    }),
  )

  // Arity mismatch: report using the inferred argument types, exactly as the
  // previous argument-typechecking pass did.
  case list.length(fields) == param_count {
    False -> {
      use #(_store, arg_types) <- result.try(
        list.try_fold(fields, #(store, []), fn(state, field) {
          let #(store, reversed) = state
          use #(store, type_) <- result.try(case field {
            glance.ShorthandField(label, _) ->
              Ok(#(
                store,
                shorthand_types
                  |> dict.get(label)
                  |> result.unwrap(types.GenericTypeVariable(label)),
              ))
            _ -> field_expression_type(environment, store, field, option.None)
          })
          Ok(#(store, [type_, ..reversed]))
        }),
      )
      Error(error.InvalidArguments(
        "(" <> types.list_to_string(parameters, environment) <> ")",
        "(" <> types.list_to_string(list.reverse(arg_types), environment) <> ")",
      ))
    }

    True -> {
      use ordered_fields <- result.try(align_argument_fields(
        fields,
        position_labels,
        param_count,
      ))

      use #(store, arg_types) <- result.try(
        list.try_fold(
          list.zip(parameters, ordered_fields),
          #(store, []),
          fn(state, pair) {
            let #(store, reversed) = state
            let #(param, field) = pair
            let #(store, resolved_param) = types.resolve(store, param)
            use #(store, arg_type) <- result.try(field_expression_type(
              environment,
              store,
              field,
              option.Some(resolved_param),
            ))
            // Polymorphic arguments (e.g. a generic function or a captured
            // call) are instantiated afresh at the call site so their type
            // variables don't leak into the callee's inference. Concrete
            // arguments are left as-is.
            let #(store, arg_type) = case functions.is_generic_type(arg_type) {
              True -> types.instantiate(store, arg_type)
              False -> #(store, arg_type)
            }
            types.unify(store, environment, arg_type, param)
            |> result.map(fn(store) { #(store, [arg_type, ..reversed]) })
            |> result.map_error(fn(_) {
              let actual =
                "("
                <> types.list_to_string(
                  list.reverse([arg_type, ..reversed]),
                  environment,
                )
                <> ")"
              error.InvalidArguments(
                "(" <> types.list_to_string(parameters, environment) <> ")",
                actual,
              )
            })
          },
        ),
      )
      Ok(#(store, list.reverse(arg_types)))
    }
  }
}

/// Type-check a single argument field, optionally against an expected type.
/// Only anonymous function literal arguments make use of the expected type
/// (see `fn_literal`); other argument shapes are typechecked without one.
fn field_expression_type(
  environment: Environment,
  store: TypeStore,
  field: glance.Field(glance.Expression),
  expected: option.Option(Type),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  case field {
    glance.LabelledField(_, _label_location, expr) ->
      case expr {
        glance.Fn(..) ->
          typecheck_with_expected(environment, store, expr, expected)
        _ -> expression(environment, store, expr)
      }
    glance.UnlabelledField(expr) ->
      case expr {
        glance.Fn(..) ->
          typecheck_with_expected(environment, store, expr, expected)
        _ -> expression(environment, store, expr)
      }
    glance.ShorthandField(label, _location) ->
      types.lookup_variable_type(environment, label)
      |> result.map(fn(type_) { #(store, type_) })
  }
}

/// Build `[0, 1, ..., n-1]`. The stdlib has no `list.range`, so the range is
/// produced by indexing a list of n units.
fn index_range(count: Int) -> List(Int) {
  list.repeat(Nil, count) |> list.index_map(fn(_, i) { i })
}

/// Align argument fields to parameter positions by label (for labelled and
/// shorthand fields) and position (for unlabelled fields), returning the fields
/// in parameter order. Reports `InvalidArgumentLabel` for unknown labels.
/// Argument count equality must be established by the caller.
fn align_argument_fields(
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

fn align_argument_fields_(
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
      index_range(param_count),
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
fn positional_argument_after_labelled(
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

type CaptureState {
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
fn fn_capture(
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
          let param_type =
            list.drop(parameters, up_to: position)
            |> list.first
            |> result.unwrap(types.GenericTypeVariable("todo"))
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

      let #(_, resolved_return) = types.resolve(store, return)
      let generalised =
        types.generalise(
          store,
          types.CallableType(
            list.reverse(remaining_reversed),
            reindexed_labels,
            resolved_return,
          ),
        )

      Ok(
        #(store, case generalised {
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
        }),
      )
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
fn next_free_slot(claimed: set.Set(Int), counter: Int) -> Int {
  case set.contains(claimed, counter) {
    True -> next_free_slot(claimed, counter + 1)
    False -> counter
  }
}

fn field_type(field: glance.Field(Type)) -> Type {
  case field {
    glance.LabelledField(_, _, type_) -> type_
    glance.UnlabelledField(type_) -> type_
    glance.ShorthandField(_, _) -> types.GenericTypeVariable("todo")
  }
}

fn too_many_arguments(
  environment: Environment,
  parameters: List(Type),
  provided: List(Type),
) -> error.TypeCheckError {
  error.InvalidArguments(
    "(" <> types.list_to_string(parameters, environment) <> ")",
    "(" <> types.list_to_string(provided, environment) <> ")",
  )
}

/// Typecheck the explicit arguments of a function capture against the
/// parameter positions they consume. Each argument is checked against the
/// expected type of its parameter so that anonymous function arguments (like
/// the callback of `list.fold(xs, _, fn(acc, x) { .. })`) get their parameter
/// types before their bodies are typechecked. Returns the typed fields and the
/// capture state describing the claimed positions.
fn typecheck_capture_arguments(
  environment: Environment,
  store: TypeStore,
  parameters: List(Type),
  labels: dict.Dict(String, Int),
  fields: List(glance.Field(glance.Expression)),
  state: CaptureState,
) -> Result(
  #(TypeStore, List(glance.Field(Type)), CaptureState),
  error.TypeCheckError,
) {
  let parameter_count = list.length(parameters)

  list.try_fold(fields, #(store, [], state), fn(acc, field) {
    let #(store, reversed, state) = acc
    let label_of = case field {
      glance.LabelledField(label, _, _) | glance.ShorthandField(label, _) ->
        option.Some(label)
      glance.UnlabelledField(_) -> option.None
    }
    let position_result = case label_of {
      option.Some(label) ->
        dict.get(labels, label)
        |> result.map_error(fn(_) {
          error.InvalidArgumentLabel(
            "(" <> labels |> dict.keys() |> string.join(", ") <> ")",
            label,
          )
        })
      option.None -> Ok(next_free_slot(state.claimed, state.counter))
    }

    use position <- result.try(position_result)

    case position >= parameter_count || set.contains(state.claimed, position) {
      True ->
        Error(too_many_arguments(
          environment,
          parameters,
          list.reverse(reversed) |> list.map(field_type),
        ))
      False -> {
        let expected =
          list.drop(parameters, up_to: position)
          |> list.first
          |> result.unwrap(types.GenericTypeVariable("todo"))
        use #(store, arg_type) <- result.try(field_expression_type(
          environment,
          store,
          field,
          option.Some(expected),
        ))
        let #(store, arg_type) = types.instantiate(store, arg_type)
        use store <- result.try(types.unify(
          store,
          environment,
          arg_type,
          expected,
        ))
        let typed_field = case field {
          glance.LabelledField(label, label_location, _) ->
            glance.LabelledField(label, label_location, arg_type)
          glance.UnlabelledField(_) -> glance.UnlabelledField(arg_type)
          glance.ShorthandField(label, _) ->
            glance.LabelledField(label, glance.Span(0, 0), arg_type)
        }
        let new_state =
          CaptureState(
            claimed: set.insert(state.claimed, position),
            consumed: [#(position, field_type(typed_field)), ..state.consumed],
            counter: case field {
              glance.UnlabelledField(_) -> position + 1
              _ -> state.counter
            },
          )
        Ok(#(store, [typed_field, ..reversed], new_state))
      }
    }
  })
  |> result.map(fn(state) {
    let #(store, fields, state) = state
    #(store, list.reverse(fields), state)
  })
}

/// Typecheck a binary operator expression. Operands are unified against the
/// expected operand type so that unannotated values (e.g. inferred function
/// parameters) are constrained by their use.
pub fn binop(
  environment: Environment,
  store: TypeStore,
  operator: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  case operator {
    glance.Pipe -> pipe(environment, store, left, right)
    _ -> {
      use #(store, left_type) <- result.try(expression(environment, store, left))
      use #(store, right_type) <- result.try(expression(
        environment,
        store,
        right,
      ))

      case operator {
        glance.And | glance.Or ->
          check_operands(
            environment,
            store,
            operator_string(operator),
            left_type,
            right_type,
            "two Bools",
            types.BoolType,
          )

        glance.Eq | glance.NotEq -> {
          case types.unify(store, environment, left_type, right_type) {
            Ok(store) -> Ok(#(store, types.BoolType))
            Error(_) ->
              Error(error.InvalidBinOp(
                operator_string(operator),
                types.to_string(environment, left_type),
                types.to_string(environment, right_type),
                "same type",
              ))
          }
        }

        glance.LtInt | glance.LtEqInt | glance.GtEqInt | glance.GtInt ->
          check_comparison_operands(
            environment,
            store,
            operator_string(operator),
            left_type,
            right_type,
            "two Ints",
            types.IntType,
          )

        glance.AddInt
        | glance.SubInt
        | glance.MultInt
        | glance.DivInt
        | glance.RemainderInt ->
          check_operands(
            environment,
            store,
            operator_string(operator),
            left_type,
            right_type,
            "two Ints",
            types.IntType,
          )

        glance.LtFloat | glance.LtEqFloat | glance.GtEqFloat | glance.GtFloat ->
          check_comparison_operands(
            environment,
            store,
            operator_string(operator),
            left_type,
            right_type,
            "two Floats",
            types.FloatType,
          )

        glance.AddFloat
        | glance.SubFloat
        | glance.MultFloat
        | glance.DivFloat ->
          check_operands(
            environment,
            store,
            operator_string(operator),
            left_type,
            right_type,
            "two Floats",
            types.FloatType,
          )

        glance.Concatenate ->
          check_operands(
            environment,
            store,
            "<>",
            left_type,
            right_type,
            "two Strings",
            types.StringType,
          )

        // Handled in the outer case before the operands are checked as
        // ordinary expressions; kept only because this case must be exhaustive.
        glance.Pipe -> pipe(environment, store, left, right)
      }
    }
  }
}

/// Unify both operands against the expected operand type, returning `Bool`
/// (the result of a comparison operator) if they both match.
fn check_comparison_operands(
  environment: Environment,
  store: TypeStore,
  operator: String,
  left: Type,
  right: Type,
  expected: String,
  expected_type: Type,
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  check_operands(
    environment,
    store,
    operator,
    left,
    right,
    expected,
    expected_type,
  )
  |> result.map(fn(state) {
    let #(store, _) = state
    #(store, types.BoolType)
  })
}

/// Unify both operands against the expected operand type, returning that type
/// if they both match. Errors use the original operand types in the message.
fn check_operands(
  environment: Environment,
  store: TypeStore,
  operator: String,
  left: Type,
  right: Type,
  expected: String,
  expected_type: Type,
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  types.unify(store, environment, left, expected_type)
  |> result.try(fn(store) {
    types.unify(store, environment, right, expected_type)
  })
  |> result.map(fn(store) { #(store, expected_type) })
  |> result.map_error(fn(_) {
    error.InvalidBinOp(
      operator,
      types.to_string(environment, left),
      types.to_string(environment, right),
      expected,
    )
  })
}

fn operator_string(operator: glance.BinaryOperator) -> String {
  case operator {
    glance.And -> "&&"
    glance.Or -> "||"
    glance.Eq -> "=="
    glance.NotEq -> "!="
    glance.LtInt -> "<"
    glance.LtEqInt -> "<="
    glance.GtEqInt -> ">="
    glance.GtInt -> ">"
    glance.LtFloat -> "<."
    glance.LtEqFloat -> "<=."
    glance.GtEqFloat -> ">=."
    glance.GtFloat -> ">."
    glance.AddInt -> "+"
    glance.AddFloat -> "+."
    glance.SubInt -> "-"
    glance.SubFloat -> "-."
    glance.MultInt -> "*"
    glance.MultFloat -> "*."
    glance.DivInt -> "/"
    glance.DivFloat -> "/."
    glance.RemainderInt -> "%"
    glance.Concatenate -> "<>"
    glance.Pipe -> "|>"
  }
}

/// Typecheck a pipe expression (`left |> right`). The left side is passed as
/// the first argument to the right side. The right side must be a callable (or
/// a call whose first argument is the piped value).
fn pipe(
  environment: Environment,
  store: TypeStore,
  left: glance.Expression,
  right: glance.Expression,
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  use #(store, left_type) <- result.try(expression(environment, store, left))
  case right {
    // `[1, 2, 3] |> echo` desugars to an `echo` with no value expression;
    // it acts as the identity function, returning the piped value.
    glance.Echo(_, option.None, message) -> {
      use #(store, _) <- result.try(case message {
        option.None -> Ok(#(store, left_type))
        option.Some(message_expr) ->
          expression(environment, store, message_expr)
      })
      Ok(#(store, left_type))
    }
    glance.Call(_, target, arguments) -> {
      use #(store, glimpse_target) <- result.try(expression(
        environment,
        store,
        target,
      ))
      pipe_value_into_callable(
        environment,
        store,
        left_type,
        glimpse_target,
        arguments,
      )
    }
    // A function literal piped a value, e.g. `value |> fn(state) { ... }`.
    // The piped value's type is threaded into the literal's first parameter
    // *before* its body is checked, so unannotated parameters can be used
    // (e.g. `state.1`); otherwise the parameter stays an unbound variable.
    glance.Fn(_, arguments, return_annotation, body) -> {
      let extra = list.length(arguments) - 1
      let extra_count = case extra > 0 {
        True -> extra
        False -> 0
      }
      let #(store, extra_types) = types.fresh_vars(store, extra_count)
      let expected =
        types.CallableType(
          [left_type, ..extra_types],
          dict.new(),
          types.InferredReturn,
        )
      use #(store, callable) <- result.try(fn_literal(
        environment,
        store,
        arguments,
        return_annotation,
        body,
        option.Some(expected),
      ))
      let #(store, pipe_result) = case callable {
        types.CallableType(_, _, return_) -> types.resolve(store, return_)
        types.GenericCallableType(_, _, return_, _) ->
          types.resolve(store, return_)
        _ -> #(store, callable)
      }
      Ok(#(store, pipe_result))
    }
    _ -> {
      use #(store, glimpse_target) <- result.try(expression(
        environment,
        store,
        right,
      ))
      pipe_value_into_callable(
        environment,
        store,
        left_type,
        glimpse_target,
        [],
      )
    }
  }
}

/// Unify the piped value with the first parameter of a callable and check any
/// remaining arguments against the remaining parameters, returning the resolved
/// and generalised return type.
fn pipe_value_into_callable(
  environment: Environment,
  store: TypeStore,
  left_type: Type,
  glimpse_target: Type,
  arguments: List(glance.Field(glance.Expression)),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  // The piped value occupies a parameter slot, so there is one more argument
  // than the explicit ones. `callable_parts` also shapes an unbound target
  // (an unannotated parameter, e.g. `request |> service`) into a fresh callable.
  use #(store, parameters, labels, return) <- result.try(callable_parts(
    environment,
    store,
    glimpse_target,
    list.length(arguments) + 1,
  ))

  // The piped value occupies the first parameter position not claimed by a
  // labelled argument, matching how `value |> f(label: x)` desugars to
  // `f(value, label: x)`; the explicit positional arguments fill the free
  // slots after it. When the pipe position and the positional arguments
  // overflow the parameters, every slot is claimed and the piped value
  // applies to the value the call returns.
  let labelled_claimed =
    list.fold(arguments, set.new(), fn(acc, field) {
      case field {
        glance.LabelledField(label, _, _) | glance.ShorthandField(label, _) ->
          case dict.get(labels, label) {
            Ok(position) -> set.insert(acc, position)
            Error(_) -> acc
          }
        glance.UnlabelledField(_) -> acc
      }
    })
  let positional_count =
    list.count(arguments, fn(field) {
      case field {
        glance.UnlabelledField(_) -> True
        _ -> False
      }
    })
  let piped_position =
    index_range(list.length(parameters) + 1)
    |> list.find(fn(position) { !set.contains(labelled_claimed, position) })
    |> result.unwrap(0)

  case piped_position + positional_count >= list.length(parameters) {
    // Every parameter slot is already claimed by an explicit argument, so the
    // call is complete and the piped value applies to the returned function.
    True -> {
      use #(store, _argument_types) <- result.try(check_arguments(
        environment,
        store,
        arguments,
        parameters,
        labels,
      ))
      pipe_value_into_result(environment, store, left_type, return)
    }
    False -> {
      case
        list.drop(parameters, up_to: piped_position)
        |> list.first
      {
        Error(_) -> Error(error.InvalidArguments("()", "a piped value"))
        Ok(first_param) -> {
          use store <- result.try(types.unify(
            store,
            environment,
            left_type,
            first_param,
          ))

          // Remove the piped parameter and re-index the remaining labels
          // relative to the remaining parameters.
          let #(before, after) = list.split(parameters, at: piped_position)
          let remaining_parameters =
            list.append(before, list.drop(after, up_to: 1))
          let shifted_labels =
            dict.fold(labels, dict.new(), fn(acc, label, position) {
              case position {
                _ if position == piped_position -> acc
                _ if position > piped_position ->
                  dict.insert(acc, label, position - 1)
                _ -> dict.insert(acc, label, position)
              }
            })

          use #(store, _argument_types) <- result.try(check_arguments(
            environment,
            store,
            arguments,
            remaining_parameters,
            shifted_labels,
          ))

          Ok(types.resolve(store, return))
        }
      }
    }
  }
}

/// The call's arguments already fill every parameter, so the piped value is
/// applied to the value the call returns, which must itself be a function.
fn pipe_value_into_result(
  environment: Environment,
  store: TypeStore,
  left_type: Type,
  return: Type,
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  use #(store, parameters, _labels, result_return) <- result.try(
    callable_parts(environment, store, return, 1)
    |> result.map_error(fn(_) { error.InvalidArguments("()", "a piped value") }),
  )
  case parameters {
    [] -> Error(error.InvalidArguments("()", "a piped value"))
    [first_param, ..] -> {
      use store <- result.try(types.unify(
        store,
        environment,
        left_type,
        first_param,
      ))
      Ok(types.resolve(store, result_return))
    }
  }
}
