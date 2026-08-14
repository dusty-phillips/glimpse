import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/set
import gleam/string
import glexer
import glimpse/error
import glimpse/internal/typecheck/bit_string_segment
import glimpse/internal/typecheck/calls
import glimpse/internal/typecheck/capture
import glimpse/internal/typecheck/exhaustive
import glimpse/internal/typecheck/functions
import glimpse/internal/typecheck/pattern
import glimpse/internal/typecheck/pipe
import glimpse/internal/typecheck/targets
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
      // The real compiler rejects lowercase identifiers containing uppercase
      // letters at the binding site ("Invalid variable name").
      use _ <- result.try(
        pattern_variable_names(pat)
        |> list.fold(Ok(Nil), fn(result, name) -> error.TypeCheckResult(Nil) {
          case result {
            Error(e) -> Error(e)
            Ok(_) ->
              case name_has_uppercase(name) {
                True -> Error(error.InvalidVariableName(name))
                False -> Ok(Nil)
              }
          }
        }),
      )
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

/// Every variable name a pattern binds, for name-case validation.
fn pattern_variable_names(pattern: glance.Pattern) -> List(String) {
  case pattern {
    glance.PatternVariable(_, name) -> [name]
    glance.PatternAssignment(_, inner, name) -> [
      name,
      ..pattern_variable_names(inner)
    ]
    glance.PatternDiscard(_, _)
    | glance.PatternInt(_, _)
    | glance.PatternFloat(_, _)
    | glance.PatternString(_, _) -> []
    glance.PatternTuple(_, elements) ->
      list.flatten(list.map(elements, pattern_variable_names))
    glance.PatternList(_, elements, tail) ->
      list.append(
        list.flatten(list.map(elements, pattern_variable_names)),
        case tail {
          option.None -> []
          option.Some(tail_pattern) -> pattern_variable_names(tail_pattern)
        },
      )
    glance.PatternBitString(_, segments) ->
      list.flatten(
        list.map(segments, fn(segment) {
          let #(pattern, _options) = segment
          pattern_variable_names(pattern)
        }),
      )
    glance.PatternConcatenate(_, _prefix, prefix_name, rest_name) ->
      list.append(
        case prefix_name {
          option.Some(glance.Named(name)) -> [name]
          _ -> []
        },
        case rest_name {
          glance.Named(name) -> [name]
          glance.Discarded(_) -> []
        },
      )
    glance.PatternVariant(_, _module, _constructor, arguments, _spread) ->
      list.flatten(
        list.map(arguments, fn(field) {
          pattern_variable_names(case field {
            glance.LabelledField(_, _, item) -> item
            glance.UnlabelledField(item) -> item
            glance.ShorthandField(label, _) ->
              glance.PatternVariable(glance.Span(-1, -1), label)
          })
        }),
      )
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
  // An empty continuation is "incomplete" in the real compiler: it warns but
  // accepts the code, typing the use expression as the callback's return type
  // without requiring the continuation to produce it. Only a non-empty
  // continuation must agree with the callback return.
  case continuation {
    [] -> {
      let #(store, resolved) = types.resolve_keep_rigid(store, return)
      Ok(#(store, environment, resolved))
    }
    _ -> {
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
      let #(store, resolved) = types.resolve_keep_rigid(store, return)
      Ok(#(store, environment, resolved))
    }
  }
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
  use _ <- result.try(targets.check_callee(environment, target))
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
      exhaustive.range(0, param_count),
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
/// Whether a lowercase identifier contains an uppercase letter, which the real
/// compiler rejects ("Invalid variable name").
fn name_has_uppercase(name: String) -> Bool {
  list.any(string.to_graphemes(name), fn(ch) {
    string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", ch)
  })
}

fn resolve_subjects(
  store: types.TypeStore,
  subject_types: List(types.Type),
) -> List(types.Type) {
  list.map(subject_types, fn(type_) {
    let #(_store, resolved) = types.resolve(store, type_)
    resolved
  })
}

/// Whether any of the resolved subject types is still unresolved at the top
/// level (an unbound inference variable, or the return of a function whose
/// signature is still inferred): a case on such a subject cannot be judged for
/// exhaustiveness yet, since unifying the clause patterns may pin its type
/// arguments (e.g. `Error(Nil)` pins the error type of a `Result` to `Nil`).
/// Nested type variables do not defer the check: they are either pinned by the
/// clause patterns (the subjects are re-resolved after unification) or they
/// are the function's own generic parameters, which the checker handles
/// structurally.
fn any_subject_unresolved(subjects: List(types.Type)) -> Bool {
  list.any(subjects, fn(type_) {
    case type_ {
      types.Var(_) | types.InferredReturn | types.TodoType -> True
      _ -> False
    }
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
    glance.String(_, value) ->
      case glexer.unescape_string(value) {
        Ok(_) -> Ok(#(store, types.StringType))
        Error(_) -> Error(error.InvalidEscape(value))
      }
    glance.Variable(_, "Nil") -> Ok(#(store, types.NilType))
    glance.Variable(_, "True") | glance.Variable(_, "False") ->
      Ok(#(store, types.BoolType))
    glance.Variable(_, name) -> {
      // The real compiler rejects any reference (not just a call) to a value
      // that has no implementation for the active target.
      use _ <- result.try(targets.check_callee(
        environment,
        glance.Variable(glance.Span(0, 0), name),
      ))
      types.lookup_variable_type(environment, name)
      |> result.map(fn(type_) {
        // Instantiate so generic values (constructors, polymorphic bindings)
        // get fresh variables at each use site.
        let #(store, type_) = types.instantiate(store, type_)
        #(store, type_)
      })
    }

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

    glance.Block(_, statements) ->
      block(environment, store, statements)
      |> result.map(fn(state) {
        let #(store, btype) = state
        #(store, btype)
      })

    glance.Panic(_, message) -> check_todo_message(environment, store, message)
    glance.Todo(_, message) -> check_todo_message(environment, store, message)

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
        Ok(#(store, types.NamespaceType(nested_defs, _))) -> {
          use _ <- result.try(targets.check_callee(
            environment,
            glance.FieldAccess(glance.Span(0, 0), container, label),
          ))
          case module_value(store, nested_defs, label) {
            Ok(state) -> Ok(state)
            Error(invalid) ->
              case environment.in_constant {
                // The namespace's defs were filtered to public definitions at
                // import time, which hides opaque variant constructors. A
                // constant's qualified reference to one of those is accepted
                // by the real compiler, so retry against the full definition
                // set when resolving inside a constant.
                True ->
                  case container_name_of(container) {
                    option.None -> Error(invalid)
                    option.Some(name) ->
                      case targets.module_path_of(environment, name) {
                        option.None -> Error(invalid)
                        option.Some(module_path) ->
                          module_definitions(environment, module_path)
                          |> result.try(fn(defs) {
                            module_value(store, defs, label)
                          })
                      }
                  }
                False -> Error(invalid)
              }
          }
        }
        Ok(#(store, container_type)) ->
          case field_access_type(environment, store, container_type, label) {
            Ok(state) -> Ok(state)
            Error(record_error) ->
              case module_field_type(environment, store, container, label) {
                Ok(state) -> {
                  use _ <- result.try(targets.check_callee(
                    environment,
                    glance.FieldAccess(glance.Span(0, 0), container, label),
                  ))
                  Ok(state)
                }
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
            glance.Variable(_, _) -> {
              use _ <- result.try(targets.check_callee(
                environment,
                glance.FieldAccess(glance.Span(0, 0), container, label),
              ))
              module_field_type(environment, store, container, label)
            }
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
      use _ <- result.try(targets.check_callee(environment, function))
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
              capture.CaptureState(set.new(), [], 0),
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
              Ok(capture.next_free_slot(
                before_state.claimed,
                before_state.counter,
              ))
          }

          use hole_position <- result.try(hole_position)

          let with_hole =
            capture.CaptureState(
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

          capture.fn_capture(
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
    option.None -> Ok(#(store, types.list_type(element_type)))
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
      types.unify(store, environment, rest_type, types.list_type(rest_element))
      |> result.map_error(mismatch)
      |> result.map(fn(store) {
        types.unify(store, environment, element_type, rest_element)
      })
      |> result.flatten
      |> result.map_error(mismatch)
      |> result.map(fn(store) { #(store, types.list_type(element_type)) })
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

  use #(store, _, param_types, annotated_flags) <- result.try(
    list.try_fold(
      arguments,
      #(store, environment.generic_vars, [], []),
      fn(state, param) {
        let #(store, generic_vars, reversed, flags) = state
        case param {
          glance.FnParameter(_, type_: option.Some(annotation)) ->
            types.type_with_store(environment, store, annotation)
            |> result.try(fn(state) {
              let #(store, type_) = state
              // A lambda's annotated type variables are rigid within its body,
              // like a function's declared type parameters.
              let #(store, generic_vars, type_) =
                functions.freshen_generics(store, generic_vars, type_)
              Ok(#(store, generic_vars, [type_, ..reversed], [True, ..flags]))
            })
          glance.FnParameter(_, type_: option.None) -> {
            let #(store, type_) = types.fresh_var(store)
            Ok(#(store, generic_vars, [type_, ..reversed], [False, ..flags]))
          }
        }
      },
    ),
  )
  let param_types = list.reverse(param_types)
  let annotated_flags = list.reverse(annotated_flags)

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

  use #(store, inferred_return) <- result.try(case body {
    // An empty body `{}` accepts any return annotation in the real compiler
    // (e.g. `fn() -> Int {}`), so it is a wildcard when a return is declared
    // or an expected type constrains it, and Nil otherwise.
    [] ->
      case return_annotation, expected {
        option.Some(_), _ -> Ok(#(store, types.TodoType))
        option.None, option.Some(_) -> Ok(#(store, types.TodoType))
        option.None, option.None -> Ok(#(store, types.NilType))
      }
    _ -> block(param_env, store, body)
  })

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
  //
  // Annotated parameters were made rigid while the body was checked (so a
  // lambda's type variables cannot be used as a concrete type); resolve them
  // back to their named generics for the lambda's own type so the lambda stays
  // polymorphic at use sites. Unannotated parameters keep the type the body
  // gave them (which may be a rigid parameter of the enclosing function), so a
  // wrapper lambda whose parameters were pinned to rigid types stays
  // monomorphic and cannot be re-instantiated past a conflicting call.
  //
  // A lambda annotation that names one of the enclosing function's type
  // parameters refers to that enclosing rigid variable, not a fresh generic:
  // after resolving back to named generics, re-substitute the enclosing rigid
  // variables for those names so the lambda's type stays tied to them. Without
  // this, `fn(x: a)` inside `fn f(x: a)` would be re-instantiable past the
  // enclosing `a`, letting a record update on a polymorphic const accept a
  // result type the real compiler rejects.
  let #(store, param_types) =
    list.fold(
      list.zip(param_types, annotated_flags),
      #(store, []),
      fn(state, pair) {
        let #(store, acc) = state
        let #(param_type, _is_annotated) = pair
        let #(store, resolved) = types.resolve(store, param_type)
        let resolved =
          resolved
          // The lambda's own type is polymorphic, so its named generics are
          // not rigid even though they were rigid inside the body.
          |> types.strip_rigidity
          |> types.substitute_type_variables(environment.generic_vars)
        #(store, [resolved, ..acc])
      },
    )
    |> fn(state) { #(state.0, list.reverse(state.1)) }
  // The return is resolved only when it was annotated: an annotated return's
  // named generics are already polymorphic, but an inferred return that the
  // body pinned to a rigid parameter of the enclosing function must stay rigid
  // (resolving it to a named generic would let a later call instantiate it).
  let #(store, return_type) = case return_annotation {
    option.Some(_) -> {
      let #(store, resolved) = types.resolve(store, return_type)
      #(store, types.strip_rigidity(resolved))
    }
    option.None -> #(store, return_type)
  }

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
      case dict.get(environment.imports.module_imports, name) {
        Ok(types.NamespaceType(nested_defs, _)) ->
          case module_value(store, nested_defs, label) {
            Ok(state) -> Ok(state)
            Error(invalid) ->
              case environment.in_constant {
                // The namespace's defs were filtered to public definitions at
                // import time, which hides opaque variant constructors. A
                // constant's qualified reference to one of those is accepted
                // by the real compiler, so retry against the full definition
                // set when resolving inside a constant.
                True ->
                  case targets.module_path_of(environment, name) {
                    option.None -> Error(invalid)
                    option.Some(module_path) ->
                      module_definitions(environment, module_path)
                      |> result.try(fn(defs) {
                        module_value(store, defs, label)
                      })
                  }
                False -> Error(invalid)
              }
          }
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
  case dict.get(environment.imports.module_environments, module) {
    Ok(other_env) ->
      case environment.in_constant {
        // A constant's qualified reference to an opaque variant constructor
        // is accepted by the real compiler, so constants resolve against the
        // full definition set.
        True -> Ok(other_env.scope.definitions)
        False ->
          Ok(
            dict.filter(other_env.scope.definitions, fn(name, _type_) {
              set.contains(other_env.scope.public_definitions, name)
            }),
          )
      }
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
  let #(store, container_type) = types.resolve_keep_rigid(store, container_type)
  case container_type {
    types.CustomType(module, name, _parameters, inferred_variant) -> {
      let definitions_result = case module == environment.current_module {
        True -> Ok(environment.scope.definitions)
        False -> {
          case dict.get(environment.imports.import_names, module) {
            Ok(namespace) ->
              case dict.get(environment.imports.module_imports, namespace) {
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
        _ ->
          // The label must be present on every variant and at the same
          // position, or no single accessor exists. A single-constructor
          // list passes these checks trivially.
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
    let assert Ok(expected_type) =
      list.drop(parameters, up_to: position) |> list.first
    let #(_, expected_type) = types.resolve_keep_rigid(store, expected_type)
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
      dict.get(environment.scope.definitions, constructor)
      |> result.replace_error(error.InvalidName(constructor))
    option.Some(module_name) -> {
      case dict.get(environment.imports.module_imports, module_name) {
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

      // Record update syntax requires the constructor to have at least one
      // labelled field: `M(..base)` on `type M { M(Int) }` is rejected by the
      // real compiler ("This constructor has no labelled fields").
      case dict.is_empty(labels) {
        True -> Error(error.RecordUpdateOnUnlabelledConstructor(constructor))
        False -> {
          // The base record and the update result must be the same variant with the
          // same type parameters, so the base's type parameters (e.g. the rigid
          // signature type variables of the record being updated) are unified with
          // the constructor's instantiated parameters before any field is checked.
          // Unifying against the *same* instantiation that produces the result type
          // keeps those parameters linked: updating `App(arguments, ..)` where
          // `arguments` is a distinct signature type variable must not let the
          // result silently become `App(arguments__zzz, ..)`.
          //
          // However a field whose type is exactly one of the record's type
          // parameters (e.g. `Box(value: a)` updated as `Box(..b, value: v)`) may
          // legitimately change that parameter, so positions updated by the update
          // are left free for the field-value unification to set. Only the
          // non-updated positions are unified against the base record's type.
          let #(store, updated) =
            updated_record_type_positions(
              store,
              parameters,
              labels,
              fields,
              constructor_return,
            )
          use store <- result.try(types.unify_record_update_base(
            store,
            environment,
            record_type,
            constructor_return,
            updated,
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
              let assert Ok(expected_type) =
                list.drop(parameters, up_to: position) |> list.first
              let #(_, expected_type) = types.resolve(store, expected_type)
              case field.item {
                option.None -> {
                  // Shorthand (`index:`) references a variable in scope; its type
                  // must match the field type, and the variable must exist.
                  types.lookup_variable_type(env, field.label)
                  |> result.replace_error(error.InvalidName(field.label))
                  |> result.try(fn(var_type) {
                    // A generalised binding (e.g. `let handlers = do_remove_event(..)`)
                    // is polymorphic; instantiating at the use site lets its named
                    // generics unify with the concrete field type instead of
                    // comparing them by name.
                    let #(store, var_type) = types.instantiate(store, var_type)
                    types.unify(store, env, var_type, expected_type)
                    |> result.map(fn(store) { #(store, env) })
                    |> result.map_error(fn(_) {
                      error.InvalidType(
                        types.to_string(env, var_type),
                        types.to_string(env, expected_type),
                        "in record update of field " <> field.label,
                      )
                    })
                  })
                }
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
      }
    }
    _ ->
      Error(error.NotCallable(types.to_string(environment, constructor_type)))
  }
}

/// Find the indices of `constructor_return`'s CustomType parameters that the
/// record update must leave free, so they are NOT unified against the base
/// record's type. A position is left free when:
///   - an updated field's expected type contains that parameter anywhere
///     (including nested inside other types, as with a field
///     `Option(Selector(message))` whose `message` parameter changes), or
///   - no field of the record references the parameter at all (a phantom
///     parameter, like `Snapshot(status)` where `status` never appears in a
///     field type).
/// Every other position is referenced only by non-updated fields, so it must
/// match the base record's type and is unified against it.
fn updated_record_type_positions(
  store: TypeStore,
  parameters: List(Type),
  labels: dict.Dict(String, Int),
  fields: List(glance.RecordUpdateField(glance.Expression)),
  constructor_return: Type,
) -> #(TypeStore, set.Set(Int)) {
  let #(store, constructor_return) = types.resolve(store, constructor_return)
  case constructor_return {
    types.CustomType(_, _, return_params, _) -> {
      let updated_field_positions =
        fields
        |> list.filter_map(fn(field) { dict.get(labels, field.label) })
        |> set.from_list

      // For each return parameter position, which field positions reference it.
      let referencing =
        list.index_map(return_params, fn(param, param_index) {
          let referencing_positions =
            list.index_map(parameters, fn(_field_type, field_index) {
              case field_index {
                _ ->
                  case list.drop(parameters, up_to: field_index) |> list.first {
                    Error(_) -> False
                    Ok(field_type) ->
                      case types.resolved_var_id(store, param) {
                        option.None -> False
                        option.Some(param_id) ->
                          types.fold_type(False, field_type, fn(found, leaf) {
                            case found {
                              True -> True
                              False ->
                                types.resolved_var_id(store, leaf)
                                == option.Some(param_id)
                            }
                          })
                      }
                  }
              }
            })
          #(
            param_index,
            set.from_list(
              list.index_map(referencing_positions, fn(is_ref, index) {
                case is_ref {
                  True -> index
                  False -> -1
                }
              })
              |> list.filter(fn(i) { i >= 0 }),
            ),
          )
        })

      // A position is left free if it is referenced by no field at all (a
      // phantom parameter), or if every field that references it is updated by
      // the update. When a parameter is shared between an updated field and a
      // field left untouched, updating only some of them would implicitly
      // change the untouched ones' types — the official compiler rejects this
      // as an "incomplete record update".
      list.fold(referencing, #(store, set.new()), fn(state, entry) {
        let #(store, acc) = state
        let #(param_index, ref_positions) = entry
        let all_referencing_updated =
          set.is_subset(ref_positions, of: updated_field_positions)
        case set.size(ref_positions) == 0 || all_referencing_updated {
          True -> #(store, set.insert(acc, param_index))
          False -> #(store, acc)
        }
      })
    }
    _ -> #(store, set.new())
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
        types.GenericTypeVariable(_, _) -> option.Some(#(param, updated))
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

/// The first element of `names` that appears twice, if any.
pub fn find_duplicate(names: List(String)) -> Option(String) {
  let #(_seen, found) =
    list.fold(names, #(set.new(), option.None), fn(state, name) {
      let #(seen, found) = state
      case found {
        option.Some(_) -> state
        option.None ->
          case set.contains(seen, name) {
            True -> #(seen, option.Some(name))
            False -> #(set.insert(seen, name), option.None)
          }
      }
    })
  found
}

/// The first element of `names` that is not a member of `known`, if any.
pub fn find_first_not_in(
  names: List(String),
  known: List(String),
) -> Option(String) {
  case names {
    [] -> option.None
    [name, ..rest] ->
      case list.contains(known, name) {
        True -> find_first_not_in(rest, known)
        False -> option.Some(name)
      }
  }
}

/// Duplicate field labels within a single record update are an error.
fn check_update_no_duplicate_fields(
  fields: List(glance.RecordUpdateField(glance.Expression)),
) -> Result(Nil, error.TypeCheckError) {
  let labels = fields |> list.map(fn(field) { field.label })
  case find_duplicate(labels) {
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
  let source = types.module_access_name(environment, module_name)
  let definitions = case source == environment.current_module {
    True -> environment.scope.definitions
    False ->
      case dict.get(environment.imports.module_imports, source) {
        Ok(types.NamespaceType(defs, _custom_types)) -> defs
        _ -> environment.scope.definitions
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
  |> list.fold_until(set.new(), fn(seen, type_) {
    let candidate = case type_ {
      types.CallableType(_, _, return_) -> our(return_)
      types.GenericCallableType(_, _, return_, _) -> our(return_)
      _ -> option.None
    }
    case candidate {
      // The caller only distinguishes one variant from several, so stop
      // scanning once a second distinct variant is found.
      option.Some(index) -> {
        let next = set.insert(seen, index)
        case set.size(next) >= 2 {
          True -> list.Stop(next)
          False -> list.Continue(next)
        }
      }
      option.None -> list.Continue(seen)
    }
  })
  |> set.size
}

/// Typecheck a `todo`/`panic` and its optional message. The message (e.g.
/// `todo("still building")`) is a normal expression that the real compiler
/// typechecks, so an undefined variable or type error inside it is reported.
fn check_todo_message(
  environment: Environment,
  store: TypeStore,
  message: option.Option(glance.Expression),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  use store <- result.try(case message {
    option.None -> Ok(store)
    option.Some(expr) -> {
      use #(store, _) <- result.try(expression(environment, store, expr))
      Ok(store)
    }
  })
  Ok(#(store, types.TodoType))
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
  // A literal String/Float segment with no options defaults to its own family
  // (`<<"x">>` and `<<1.5>>` are valid), but once any option is present the
  // family is forced by the options: `<<"x":8>>` and `<<1.5:8>>` are rejected
  // because an integer size makes the segment an `Int`.
  let expected_family = case options {
    [] ->
      case value_expr {
        glance.String(_, _) -> types.StringType
        glance.Float(_, _) -> types.FloatType
        _ -> types.IntType
      }
    _ -> bit_string_segment.segment_type(options)
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
  use store <- result.try(check_expression_options(options, store))
  check_literal_sizes(environment, store, options)
}

/// Reject segment options that the real compiler only allows in bit-array
/// *patterns*: `signed`/`unsigned` and a `bytes` type option are meaningless
/// for an expression that is just built (its byte order, interpretation and
/// segment type are fixed by the value). A `unit` without an accompanying
/// `size` is also rejected, in both expressions and patterns.
fn check_expression_options(
  options: List(glance.BitStringSegmentOption(glance.Expression)),
  store: TypeStore,
) -> error.TypeCheckResult(TypeStore) {
  let has_size =
    list.any(options, fn(option) {
      case option {
        glance.SizeOption(_) | glance.SizeValueOption(_) -> True
        _ -> False
      }
    })
  let has_unit =
    list.any(options, fn(option) {
      case option {
        glance.UnitOption(_) -> True
        _ -> False
      }
    })
  let has_pattern_only =
    list.any(options, fn(option) {
      case option {
        glance.SignedOption | glance.UnsignedOption | glance.BytesOption -> True
        _ -> False
      }
    })
  case has_pattern_only || has_unit && !has_size {
    True -> Error(error.InvalidBitStringSegment("signed"))
    False -> Ok(store)
  }
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

  // Exhaustiveness is checked on the *resolved* subject types. A subject whose
  // type is not yet known (an unbound inference variable, or the return of a
  // function whose signature is still inferred) cannot be judged: deferring
  // matches the real compiler, which checks exhaustiveness after all bodies
  // are analysed. The second body pass, where every signature has been
  // written back, re-runs this check on the resolved types. The subjects are
  // resolved *after* the clause patterns have unified with them, so a pattern
  // like `Error(Nil)` that pins an otherwise-inferred type argument (Nil) is
  // visible to the check.
  case clauses {
    [] -> {
      let resolved_subjects = resolve_subjects(store, subject_types)
      case any_subject_unresolved(resolved_subjects) {
        True -> Error(error.CaseClauseMismatch("no clauses", "any"))
        False ->
          case exhaustive.check(environment, resolved_subjects, []) {
            option.Some(missing) ->
              Error(error.InexhaustivePattern(string.join(missing, "\n")))
            option.None -> Error(error.CaseClauseMismatch("no clauses", "any"))
          }
      }
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
                    types.TodoType | types.InferredReturn -> False
                    _ -> True
                  }
                })
                |> result.unwrap(types.TodoType)
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
          case any_subject_unresolved(resolve_subjects(store, subject_types)) {
            True -> Ok(case_state)
            False ->
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
        alternative_env.scope.definitions,
        Ok(store),
        fn(result, name, alternative_type) {
          use store <- result.try(result)
          case dict.get(pattern_env.scope.definitions, name) {
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
  |> result.map(fn(first) {
    string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", first)
  })
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
  case dict.get(environment.scope.definitions, name) {
    Ok(type_) -> {
      // The binding may still be an unlinked variable that only resolves to
      // the concrete custom type through the store (e.g. a case subject bound
      // to a fresh variable by an earlier clause). Resolve it first so the
      // variant can be pinned on the concrete type, not lost on the variable.
      // Rigid type parameters are preserved: refining `Result(a, e)` to the
      // `Ok` variant must not turn the rigid `a`/`e` into instantiable named
      // generics, or a later branch returning the subject loses the rigidity.
      let #(store, resolved) = types.resolve_keep_rigid(store, type_)
      let refined = types.set_custom_type_variant(resolved, variant_index)
      #(
        store,
        Environment(
          ..environment,
          scope: types.Scope(
            ..environment.scope,
            definitions: dict.insert(
              environment.scope.definitions,
              name,
              refined,
            ),
          ),
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
pub fn is_callable_type(type_: types.Type) -> Bool {
  case type_ {
    types.CallableType(..) | types.GenericCallableType(..) -> True
    _ -> False
  }
}

/// The parameters, labels, and return of an arbitrary expression call target.
/// A target that is a bare unbound variable (an unannotated higher-order
/// parameter) is constrained to a fresh callable taking the given number of
/// arguments.
fn higher_order_call(
  environment: Environment,
  store: TypeStore,
  target: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
) -> error.TypeCheckResult(
  #(TypeStore, List(Type), dict.Dict(String, Int), Type),
) {
  expression(environment, store, target)
  |> result.try(fn(state) {
    let #(store, glimpse_target) = state
    calls.callable_parts(
      environment,
      store,
      glimpse_target,
      list.length(arguments),
    )
  })
}

pub fn call(
  environment: Environment,
  store: TypeStore,
  target: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  // `todo(expr)` and `panic(expr)` are calls to the prelude wildcard values:
  // the message is typechecked as a normal expression and the call itself has
  // the wildcard type (unifies with anything). Glance represents them as a
  // `Todo`/`Panic` callee, not a `Variable("todo")`.
  case target {
    glance.Todo(_, _) | glance.Panic(_, _) -> {
      use #(store, _) <- result.try(
        list.try_fold(arguments, #(store, Nil), fn(state, argument) {
          let #(store, _) = state
          use #(store, _) <- result.try(case argument {
            glance.UnlabelledField(expr) -> expression(environment, store, expr)
            glance.LabelledField(label, _, _) ->
              Error(error.UnexpectedLabelledArgument(label))
            glance.ShorthandField(label, _) ->
              Error(error.UnexpectedLabelledArgument(label))
          })
          Ok(#(store, Nil))
        }),
      )
      Ok(#(store, types.TodoType))
    }
    _ -> do_call(environment, store, target, arguments)
  }
}

fn do_call(
  environment: Environment,
  store: TypeStore,
  target: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  use _ <- result.try(targets.check_callee(environment, target))
  // A recursive self-call is checked against the function's own rigid type
  // variables (monomorphic recursion), not a fresh instantiation: the real
  // compiler rejects a self-call that passes a different rigid type variable
  // for a parameter. Look the callee's stored signature up and substitute its
  // declared type variables with the enclosing function's rigid variables, so
  // the argument unification sees the same rigid variables the body uses.
  use #(store, parameters, labels, return) <- result.try(case target {
    glance.Variable(_, callee)
      if environment.current_function == option.Some(callee)
    -> {
      // The name only denotes a recursive call when it resolves to the current
      // function's own signature. A local binding (a parameter or `let`)
      // shadows the name, in which case the call is to that local value, not a
      // self-call, and must be checked as an ordinary higher-order call.
      case calls.placeholder_callee(environment, callee) {
        True -> higher_order_call(environment, store, target, arguments)
        False ->
          case dict.get(environment.scope.definitions, callee) {
            Ok(callee_type) -> {
              case is_callable_type(callee_type) {
                True -> {
                  // Substitute the enclosing function's declared type variables
                  // (the rigid vars) for the callee's same-named generics, so the
                  // self-call is checked against the enclosing rigid vars rather
                  // than fresh instantiations. Any generics the enclosing function
                  // does not declare (unannotated inferred params) are
                  // instantiated to fresh vars afterwards.
                  let substituted =
                    types.substitute_type_variables(
                      callee_type,
                      environment.generic_vars,
                    )
                  let #(store, instantiated) =
                    types.instantiate(store, substituted)
                  case instantiated {
                    types.GenericCallableType(parameters, labels, return, _)
                    | types.CallableType(parameters, labels, return) ->
                      Ok(#(store, parameters, labels, return))
                    _ -> Ok(#(store, [], dict.new(), types.NilType))
                  }
                }
                False ->
                  higher_order_call(environment, store, target, arguments)
              }
            }
            Error(_) -> higher_order_call(environment, store, target, arguments)
          }
      }
    }
    _ -> higher_order_call(environment, store, target, arguments)
  })

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
        calls.record_generic_constraints(environment, store, callee, arguments)
      }
      constraints
      |> result.map(fn(store) {
        case calls.placeholder_callee(environment, callee) {
          True -> types.fresh_var_with_source(store, "r_" <> callee)
          False -> #(store, return)
        }
      })
    }
    _ -> Ok(#(store, return))
  })

  Ok(#(store, return))
}

/// Type-check call arguments against their parameter types.
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
                  |> result.unwrap(types.GenericTypeVariable(label, False)),
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
      use ordered_fields <- result.try(calls.align_argument_fields(
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
            let #(store, resolved_param) =
              types.resolve_keep_rigid(store, param)
            use #(store, arg_type) <- result.try(field_expression_type(
              environment,
              store,
              field,
              option.Some(resolved_param),
            ))
            // Polymorphic arguments (a generic function, capture, or
            // constructor) are instantiated afresh at the call site so their
            // type variables don't leak into the callee's inference. Concrete
            // arguments — including a value like `Decoder(message)` whose type
            // parameter is the enclosing function's rigid signature variable
            // (marked `rigid: True` on the generic) — are left as-is.
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
          pipe.check_operands(
            environment,
            store,
            pipe.operator_string(operator),
            left_type,
            right_type,
            "two Bools",
            types.BoolType,
          )

        glance.Eq | glance.NotEq -> {
          case types.unify(store, environment, left_type, right_type) {
            Ok(store) -> Ok(#(store, types.BoolType))
            Error(_) -> {
              let #(store, resolved_left) = types.resolve(store, left_type)
              let #(_store, resolved_right) = types.resolve(store, right_type)
              Error(error.InvalidBinOp(
                pipe.operator_string(operator),
                types.to_string(environment, resolved_left),
                types.to_string(environment, resolved_right),
                "same type",
              ))
            }
          }
        }

        glance.LtInt | glance.LtEqInt | glance.GtEqInt | glance.GtInt ->
          pipe.check_comparison_operands(
            environment,
            store,
            pipe.operator_string(operator),
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
          pipe.check_operands(
            environment,
            store,
            pipe.operator_string(operator),
            left_type,
            right_type,
            "two Ints",
            types.IntType,
          )

        glance.LtFloat | glance.LtEqFloat | glance.GtEqFloat | glance.GtFloat ->
          pipe.check_comparison_operands(
            environment,
            store,
            pipe.operator_string(operator),
            left_type,
            right_type,
            "two Floats",
            types.FloatType,
          )

        glance.AddFloat
        | glance.SubFloat
        | glance.MultFloat
        | glance.DivFloat ->
          pipe.check_operands(
            environment,
            store,
            pipe.operator_string(operator),
            left_type,
            right_type,
            "two Floats",
            types.FloatType,
          )

        glance.Concatenate ->
          pipe.check_operands(
            environment,
            store,
            pipe.operator_string(operator),
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
      use _ <- result.try(targets.check_callee(environment, target))
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
      use _ <- result.try(targets.check_callee(environment, right))
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
  // `value |> todo` desugars to `todo(value, ...)`: the wildcard value accepts
  // any piped value and arguments (they are its messages) and returns the
  // wildcard type, so nothing needs to be callable.
  let #(store, resolved_target) = types.resolve(store, glimpse_target)
  case resolved_target {
    types.TodoType -> {
      use #(store, _) <- result.try(
        list.try_fold(arguments, #(store, Nil), fn(state, argument) {
          let #(store, _) = state
          use #(store, _) <- result.try(case argument {
            glance.UnlabelledField(expr) -> expression(environment, store, expr)
            glance.LabelledField(label, _, _) ->
              Error(error.UnexpectedLabelledArgument(label))
            glance.ShorthandField(label, _) ->
              Error(error.UnexpectedLabelledArgument(label))
          })
          Ok(#(store, Nil))
        }),
      )
      Ok(#(store, types.TodoType))
    }
    _ ->
      calls.callable_parts(
        environment,
        store,
        resolved_target,
        list.length(arguments) + 1,
      )
      |> result.try(fn(state) {
        let #(store, parameters, labels, return) = state
        pipe_value_into_callable_parts(
          environment,
          store,
          left_type,
          arguments,
          parameters,
          labels,
          return,
        )
      })
  }
}

/// The pipe mechanics once the target's callable shape is known: the piped
/// value occupies the first parameter position not claimed by a labelled
/// argument, the explicit positional arguments fill the free slots after it,
/// and the call is completed (or the piped value applies to the returned
/// function when every slot is claimed).
fn pipe_value_into_callable_parts(
  environment: Environment,
  store: TypeStore,
  left_type: Type,
  arguments: List(glance.Field(glance.Expression)),
  parameters: List(Type),
  labels: dict.Dict(String, Int),
  return: Type,
) -> error.TypeCheckResult(#(TypeStore, Type)) {
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
    exhaustive.range(0, list.length(parameters) + 1)
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
      pipe.pipe_value_into_result(environment, store, left_type, return)
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
  state: capture.CaptureState,
) -> Result(
  #(TypeStore, List(glance.Field(Type)), capture.CaptureState),
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
      option.None -> Ok(capture.next_free_slot(state.claimed, state.counter))
    }

    use position <- result.try(position_result)

    case position >= parameter_count || set.contains(state.claimed, position) {
      True ->
        Error(capture.too_many_arguments(
          environment,
          parameters,
          list.reverse(reversed) |> list.map(capture.field_type),
        ))
      False -> {
        let assert Ok(expected) =
          list.drop(parameters, up_to: position) |> list.first
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
          capture.CaptureState(
            claimed: set.insert(state.claimed, position),
            consumed: [
              #(position, capture.field_type(typed_field)),
              ..state.consumed
            ],
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

/// The variable name a module-qualified access's container denotes, if it is a
/// plain variable.
fn container_name_of(container: glance.Expression) -> option.Option(String) {
  case container {
    glance.Variable(_, name) -> option.Some(name)
    _ -> option.None
  }
}
