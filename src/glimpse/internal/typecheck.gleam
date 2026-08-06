import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/set
import gleam/string
import glimpse/error
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
          pattern.typecheck_pattern(environment, store, type_, pat)
          |> pattern_must_be_irrefutable(environment, type_, pat)
          |> result.map(fn(state) {
            let #(store, env) = state
            #(store, env, type_)
          })
        }
        glance.LetAssert(_) -> {
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
  #(
    TypeStore,
    List(types.Type),
    List(types.Type),
    dict.Dict(String, Int),
    types.Type,
  ),
) {
  case target {
    types.CallableType(target_arguments, _, _)
    | types.GenericCallableType(target_arguments, _, _, _) -> {
      let #(store, parameters, labels, return) =
        types.instantiate_callable(store, target)
      Ok(#(store, target_arguments, parameters, labels, return))
    }
    types.Var(_) | types.InferredReturn -> {
      let #(store, parameters) = types.fresh_vars(store, argument_count)
      let #(store, return) = types.fresh_var(store)
      let callable = types.CallableType(parameters, dict.new(), return)
      types.unify(store, environment, target, callable)
      |> result.map(fn(store) {
        #(store, parameters, parameters, dict.new(), return)
      })
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

      let given_parameters =
        list.take(parameters, up_to: list.length(parameters) - 1)

      use #(store, _argument_types) <- result.try(check_arguments(
        environment,
        store,
        arguments,
        given_parameters,
        labels,
      ))

      // Fold the use patterns against the callback parameter only after the
      // explicit arguments are unified, so the callback's types are resolved
      // before they are generalised into the bound pattern variables.
      use #(store, env, callback_return) <- result.try(fold_use_patterns(
        environment,
        store,
        patterns,
        list.length(arguments),
        parameters,
      ))

      // The statements after the `use` are the callback body, checked against
      // the callback's declared return type.
      check_continuation(env, store, callback_return, return, continuation)
    }
    _ -> Error(error.NotCallable(types.to_string(environment, glimpse_target)))
  }
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
      use #(store, env, callback_return) <- result.try(fold_use_patterns(
        environment,
        store,
        patterns,
        0,
        parameters,
      ))
      check_continuation(env, store, callback_return, return, continuation)
    }
    _ -> Error(error.NotCallable(types.to_string(environment, target_type)))
  }
}

/// The parameters given to a `use` statement are the call's explicit arguments
/// plus one implicit callback parameter. The callback's parameters are matched
/// against the use patterns. This extracts the callback's parameter types and
/// return type, folds the use patterns against the callback's parameter types,
/// and checks the explicit argument count against the callable's parameters.
fn fold_use_patterns(
  environment: Environment,
  store: TypeStore,
  patterns: List(glance.UsePattern),
  given_argument_count: Int,
  parameters: List(types.Type),
) -> error.TypeCheckResult(#(TypeStore, Environment, Type)) {
  case list.length(parameters) == given_argument_count + 1 {
    False -> Error(error.InvalidUse(list.length(patterns)))
    True -> {
      let callback_parameter =
        list.last(parameters) |> result.unwrap(types.IntType)
      let callback_types = case callback_parameter {
        types.CallableType(callback_params, _, callback_return) ->
          Ok(#(callback_params, callback_return))
        types.GenericCallableType(callback_params, _, callback_return, _) ->
          Ok(#(callback_params, callback_return))
        _ ->
          Error(
            error.NotCallable(types.to_string(environment, callback_parameter)),
          )
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
                  pattern.typecheck_pattern(
                    env,
                    store,
                    type_,
                    use_pattern.pattern,
                  )
                  |> pattern_must_be_irrefutable(
                    env,
                    type_,
                    use_pattern.pattern,
                  )
                option.Some(annotation) -> {
                  use #(store, annotated) <- result.try(types.type_with_store(
                    env,
                    store,
                    annotation,
                  ))
                  use store <- result.try(types.unify(
                    store,
                    env,
                    type_,
                    annotated,
                  ))
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
    Ok(state) ->
      case exhaustive.check(environment, [type_], [[pattern]]) {
        option.Some(missing) ->
          Error(error.InexhaustivePattern(string.join(missing, "\n")))
        option.None -> Ok(state)
      }
  }
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
    glance.Float(_, _) -> Ok(#(store, types.FloatType))
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
            Error(_) -> {
              let #(store, elements) = fresh_tuple_elements(store, index + 1)
              case
                types.unify(
                  store,
                  environment,
                  tuple_type,
                  types.TupleType(elements),
                )
              {
                Ok(store) -> {
                  let element =
                    list.drop(elements, up_to: index)
                    |> list.first
                    |> result.unwrap(types.GenericTypeVariable("todo"))
                  Ok(#(store, element))
                }
                Error(_) ->
                  Error(error.UnexpectedType(
                    types.to_string(environment, tuple_type),
                    "a tuple",
                  ))
              }
            }
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
          let #(value_expr, _options) = segment
          expression(environment, store, value_expr)
          |> result.map(fn(state) {
            let #(store, _type) = state
            #(store, Nil)
          })
        }),
      )
      Ok(#(store, types.BitArrayType))
    }

    glance.Case(_, subjects, clauses) ->
      case_expression(environment, store, subjects, clauses)

    glance.Echo(_, _expression, message) -> {
      case message {
        option.None -> Ok(#(store, types.NilType))
        option.Some(message_expr) -> {
          use #(store, _) <- result.try(expression(
            environment,
            store,
            message_expr,
          ))
          Ok(#(store, types.NilType))
        }
      }
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

fn fresh_tuple_elements(
  store: TypeStore,
  count: Int,
) -> #(TypeStore, List(Type)) {
  case count {
    0 -> #(store, [])
    _ -> {
      let #(store, rest) = fresh_tuple_elements(store, count - 1)
      let #(store, var_) = types.fresh_var(store)
      #(store, [var_, ..rest])
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
        option.None -> Ok(#(store, types.GenericTypeVariable("todo")))
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

/// Typecheck a function literal. Parameters without annotations are inferred
/// from their use within the body.
///
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

      // Constructor names differ from the type name for multi-constructor
      // types, so find the constructor whose return type is this custom type
      // and which carries the label.
      let constructor_result =
        dict.fold(
          definitions,
          Error(error.InvalidFieldAccess(
            types.to_string(environment, container_type),
            label,
          )),
          fn(acc, _ctor_name, def) {
            case acc {
              Ok(_) -> acc
              Error(_) -> {
                case def {
                  types.CallableType(..) | types.GenericCallableType(..) -> {
                    let #(store, parameters, labels, return) =
                      types.instantiate_callable(store, def)
                    let is_target = case return {
                      types.CustomType(
                        return_module,
                        return_name,
                        _,
                        return_variant,
                      ) -> {
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
                    case is_target && dict.has_key(labels, label) {
                      True -> Ok(#(store, parameters, labels, return))
                      False -> acc
                    }
                  }
                  _ -> acc
                }
              }
            }
          },
        )

      use constructor_data <- result.try(constructor_result)
      let #(store, parameters, labels, return_type) = constructor_data

      // Unify the container with the constructor's return type so the field
      // type is expressed in terms of the container's actual type parameters
      // (e.g. `key.function` on `Decoder(key)` yields `key`, not a fresh var).
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
    _ ->
      Error(error.InvalidFieldAccess(
        types.to_string(environment, container_type),
        label,
      ))
  }
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

  case clauses {
    [] ->
      case exhaustive.check(environment, subject_types, []) {
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
        Ok(case_state) ->
          case exhaustive.check(environment, subject_types, alternatives) {
            option.Some(missing) ->
              Error(error.InexhaustivePattern(string.join(missing, "\n")))
            option.None -> Ok(case_state)
          }
      }
    }
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

  let pattern_env =
    dict.fold(agreed, pattern_env, fn(env, name, index) {
      apply_variant_refinement(env, name, index)
    })

  use #(store, guard_type) <- result.try(case clause.guard {
    option.None -> Ok(#(store, types.BoolType))
    option.Some(guard_expr) -> expression(pattern_env, store, guard_expr)
  })

  case types.unify(store, pattern_env, guard_type, types.BoolType) {
    Ok(store) -> expression(pattern_env, store, clause.body)
    Error(_) ->
      Error(error.InvalidGuard(types.to_string(pattern_env, guard_type)))
  }
}

/// Replace a subject variable's binding with a copy marked as a known variant,
/// so field access on it uses the matching constructor's field types.
fn apply_variant_refinement(
  environment: Environment,
  name: String,
  variant_index: Int,
) -> Environment {
  case dict.get(environment.definitions, name) {
    Ok(type_) ->
      Environment(
        ..environment,
        definitions: dict.insert(
          environment.definitions,
          name,
          types.set_custom_type_variant(type_, variant_index),
        ),
      )
    Error(_) -> environment
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

  use #(store, _target_arguments, parameters, labels, return) <- result.try(
    callable_parts(environment, store, glimpse_target, list.length(arguments)),
  )

  use #(store, _argument_types) <- result.try(check_arguments(
    environment,
    store,
    arguments,
    parameters,
    labels,
  ))

  Ok(types.resolve(store, return))
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
  use #(store, _target_arguments, parameters, labels, return) <- result.try(
    callable_parts(
      environment,
      store,
      glimpse_target,
      list.length(arguments) + 1,
    ),
  )

  // The piped value occupies the first parameter position not already
  // claimed by a labelled argument, matching how `value |> f(label: x)`
  // desugars to `f(value, label: x)` and positional arguments fill the
  // remaining slots in order.
  let claimed_positions =
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
  let piped_position =
    index_range(list.length(parameters) + 1)
    |> list.find(fn(position) { !set.contains(claimed_positions, position) })
    |> result.unwrap(0)

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

      // Remove the piped parameter and re-index the remaining labels relative
      // to the remaining parameters.
      let #(before, after) = list.split(parameters, at: piped_position)
      let remaining_parameters = list.append(before, list.drop(after, up_to: 1))
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
