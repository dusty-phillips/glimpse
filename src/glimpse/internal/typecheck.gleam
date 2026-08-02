import glance
import gleam/dict
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import glimpse/error
import glimpse/internal/typecheck/functions
import glimpse/internal/typecheck/pattern
import glimpse/internal/typecheck/types.{
  type Environment, type Type, type TypeStore,
}

/// Typecheck a sequence of statements, threading the environment and type store
/// through each one. Returns the type of the final statement, or Nil if the
/// block is empty.
///
/// A `use` statement desugars to a call `f(args, fn(..) { .. })` whose value is
/// `f`'s return type, and the statements after it are the callback body. So when
/// the block contains a `use` statement, the block's type is the first
/// (outermost) `use` statement's return type rather than the last statement's.
pub fn block(
  environment: Environment,
  store: TypeStore,
  statements: List(glance.Statement),
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  list.fold_until(
    statements,
    Ok(#(store, environment, types.NilType, option.None)),
    fn(state, stmnt) {
      case state {
        Error(_) -> list.Stop(state)
        Ok(#(store, env, _type, use_type)) -> {
          let statement_result = statement(env, store, stmnt)
          case statement_result {
            Error(_) ->
              list.Stop(
                result.map(statement_result, fn(t) {
                  let #(s, e, ty) = t
                  #(s, e, ty, use_type)
                }),
              )
            Ok(#(store, env, stmt_type)) -> {
              echo "BLOCK statement type=" <> types.raw_show(stmt_type)
              let new_use_type = case stmnt {
                glance.Use(..) ->
                  case use_type {
                    option.Some(_) -> use_type
                    option.None -> option.Some(stmt_type)
                  }
                _ -> use_type
              }
              list.Continue(Ok(#(store, env, stmt_type, new_use_type)))
            }
          }
        }
      }
    },
  )
  |> result.map(fn(state) {
    let #(store, _env, last_type, use_type) = state
    let block_type = option.unwrap(use_type, last_type)
    #(store, block_type)
  })
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
        option.None -> Ok(option.None)
        option.Some(annotation) ->
          types.type_(environment, annotation)
          |> result.map(option.Some)
      }

      use annotated_type <- result.try(annotated_type_result)

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
          use #(store, env) <- result.try(pattern.typecheck_pattern(
            environment,
            store,
            type_,
            pat,
          ))
          Ok(#(store, env, type_))
        }
        glance.LetAssert(_) -> {
          use #(store, env) <- result.try(pattern.typecheck_pattern(
            environment,
            store,
            type_,
            pat,
          ))
          Ok(#(store, env, types.NilType))
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

    glance.Use(_, patterns, function_expr) ->
      use_statement(environment, store, patterns, function_expr)
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
      echo "    CALLABLEPARTS callable nargs="
      echo argument_count
      echo " target="
      echo types.to_string(environment, target)
      let #(store, parameters, labels, return) =
        types.instantiate_callable(store, target)
      Ok(#(store, target_arguments, parameters, labels, return))
    }
    types.Var(_) -> {
      echo "    CALLABLEPARTS var nargs="
      echo argument_count
      let #(store, parameters) = types.fresh_vars(store, argument_count)
      let #(store, return) = types.fresh_var(store)
      let callable = types.CallableType(parameters, dict.new(), return)
      echo "    CALLABLEPARTS params="
      echo types.list_to_string(parameters, environment)
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
) -> error.TypeCheckResult(#(TypeStore, Environment, Type)) {
  case function_expr {
    glance.Call(_, target, arguments) ->
      use_call(environment, store, patterns, target, arguments)
    _ -> use_statement_with_type(environment, store, patterns, function_expr)
  }
}

/// Typecheck a `use` statement where the function is a call, e.g.
/// `use y <- with_x(10)`. The given arguments are checked against all but the
/// last parameter of the function; the last parameter is the callback that the
/// `use` expression provides.
fn use_call(
  environment: Environment,
  store: TypeStore,
  patterns: List(glance.UsePattern),
  target: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
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
      use #(store, env, _callback_return) <- result.try(fold_use_patterns(
        environment,
        store,
        patterns,
        list.length(arguments),
        parameters,
      ))

      // The `use` expression has the type of the function call it desugars to
      // (`f(y, fn(x) { body })`), i.e. the use function's return type, not the
      // callback's.
      let #(store, resolved) = types.resolve(store, return)
      Ok(#(store, env, resolved))
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
) -> error.TypeCheckResult(#(TypeStore, Environment, Type)) {
  use #(store, target_type) <- result.try(expression(
    environment,
    store,
    function_expr,
  ))

  case target_type {
    types.CallableType(parameters, _, return)
    | types.GenericCallableType(parameters, _, return, _) -> {
      use #(store, env, _callback_return) <- result.try(fold_use_patterns(
        environment,
        store,
        patterns,
        0,
        parameters,
      ))
      let #(store, resolved) = types.resolve(store, return)
      Ok(#(store, env, resolved))
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
              pattern.typecheck_pattern(env, store, type_, use_pattern.pattern)
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
      // A bare module alias used as a namespace (e.g. `token.DotDot`) must
      // resolve to the namespace even when a value with the same name exists.
      let container_result = case container {
        glance.Variable(_, name) ->
          case dict.get(environment.module_imports, name) {
            Ok(namespace) -> Ok(#(store, namespace))
            Error(_) -> expression(environment, store, container)
          }
        _ -> expression(environment, store, container)
      }
      use #(store, container_expression_type) <- result.try(container_result)
      case container_expression_type {
        types.NamespaceType(nested_defs, _nested_types) ->
          nested_defs
          |> dict.get(label)
          |> result.replace_error(error.InvalidName(label))
          |> result.map(fn(type_) {
            let #(store, type_) = types.instantiate(store, type_)
            #(store, type_)
          })
        type_ -> field_access_type(environment, store, type_, label)
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

    glance.Echo(_, message) -> {
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

          use #(store, typed_before) <- result.try(fold_fields(
            environment,
            store,
            arguments_before,
          ))
          use #(store, typed_after) <- result.try(fold_fields(
            environment,
            store,
            arguments_after,
          ))

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
    option.None -> Ok(#(store, types.ListType(element_type)))
    option.Some(rest_expr) -> {
      use #(store, rest_type) <- result.try(expression(
        environment,
        store,
        rest_expr,
      ))
      let #(store, rest_element) = case rest_type {
        types.ListType(rest_element) -> #(store, rest_element)
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
      types.unify(store, environment, rest_type, types.ListType(rest_element))
      |> result.map_error(mismatch)
      |> result.map(fn(store) {
        types.unify(store, environment, element_type, rest_element)
      })
      |> result.flatten
      |> result.map_error(mismatch)
      |> result.map(fn(store) { #(store, types.ListType(element_type)) })
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
          types.type_(environment, annotation)
          |> result.map(fn(type_) { #(store, [type_, ..reversed]) })
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
      use annotated <- result.try(types.type_(environment, annotation))
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

/// Typecheck a field access expression (`record.label`). The container must
/// be a custom type whose constructor has a parameter with the given label.
fn field_access_type(
  environment: Environment,
  store: TypeStore,
  container_type: types.Type,
  label: String,
) -> error.TypeCheckResult(#(TypeStore, types.Type)) {
  echo "FIELDSEL container="
    <> types.to_string(environment, container_type)
    <> " label="
    <> label
  case container_type {
    types.CustomType(module, name, _parameters) -> {
      let definitions_result = case module == environment.current_module {
        True -> Ok(environment.definitions)
        False -> {
          case dict.get(environment.module_imports, module) {
            Ok(types.NamespaceType(nested_defs, _)) -> Ok(nested_defs)
            _ ->
              Error(error.InvalidFieldAccess(
                types.to_string(environment, container_type),
                label,
              ))
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
                      types.CustomType(return_module, return_name, _) ->
                        return_module == module && return_name == name
                      _ -> False
                    }
                    case is_target && dict.has_key(labels, label) {
                      True -> Ok(#(store, parameters, labels))
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
      let #(store, parameters, labels) = constructor_data
      dict.get(labels, label)
      |> result.map(fn(position) {
        let expected_type =
          list.drop(parameters, up_to: position)
          |> list.first
          |> result.unwrap(types.GenericTypeVariable("todo"))
        let #(_, expected_type) = types.resolve(store, expected_type)
        let expected_type = types.generalise(store, expected_type)
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

      use store <- result.try(types.unify(
        store,
        environment,
        record_type,
        constructor_return,
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
          let expected_type = types.generalise(store, expected_type)
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
        #(store, record_type)
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

  case clauses {
    [] -> Error(error.CaseClauseMismatch("no clauses", "any"))
    [_first_clause, ..] -> {
      // Typecheck every clause body sequentially, threading the store so each
      // clause gets a distinct namespace of inference variables. Unifying the
      // bodies afterwards then cannot conflate vars that belong to different
      // clauses.
      use #(store, clause_types) <- result.try(
        list.try_fold(clauses, #(store, []), fn(state, clause) {
          let #(store, reversed) = state
          clause_body_type(environment, store, subject_types, clause)
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
          |> result.map(fn(store) { #(store, first_body_type) })
      }
    }
  }
}

fn clause_body_type(
  environment: Environment,
  store: TypeStore,
  subject_types: List(Type),
  clause: glance.Clause,
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  // `clause.patterns` is a list of OR-alternatives, each a list of patterns
  // aligned with the subjects. Typecheck every alternative against the base
  // environment so bindings from one alternative don't leak into another.
  use #(store, pattern_env) <- result.try(
    list.try_fold(
      clause.patterns,
      #(store, environment),
      fn(state, alternative) {
        let #(store, _) = state
        list.try_fold(
          list.zip(subject_types, alternative),
          #(store, environment),
          fn(state, pair) {
            let #(store, env) = state
            let #(subject_type, pattern) = pair
            pattern.typecheck_pattern(env, store, subject_type, pattern)
          },
        )
      },
    ),
  )

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
        glance.ShorthandField(label) ->
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
            glance.ShorthandField(label) ->
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
    glance.LabelledField(_, expr) ->
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
    glance.ShorthandField(label) ->
      types.lookup_variable_type(environment, label)
      |> result.map(fn(type_) { #(store, type_) })
  }
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
        glance.LabelledField(label, _) -> #(
          positional,
          dict.insert(labelled, label, field),
        )
        glance.ShorthandField(label) -> #(
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
      list.range(0, param_count - 1),
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
    glance.LabelledField(label, type_) ->
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
    glance.ShorthandField(label) -> Error(error.InvalidName(label))
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
    glance.LabelledField(_, type_) -> type_
    glance.UnlabelledField(type_) -> type_
    glance.ShorthandField(_) -> types.GenericTypeVariable("todo")
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

/// Typecheck each call argument, threading the store through the argument
/// expressions.
fn fold_fields(
  environment: Environment,
  store: TypeStore,
  fields: List(glance.Field(glance.Expression)),
) -> error.TypeCheckResult(#(TypeStore, List(glance.Field(types.Type)))) {
  list.try_fold(fields, #(store, []), fn(state, field) {
    let #(store, reversed) = state
    call_field(environment, store, field)
    |> result.map(fn(state) {
      let #(store, field) = state
      #(store, [field, ..reversed])
    })
  })
  |> result.map(fn(state) {
    let #(store, fields) = state
    #(store, list.reverse(fields))
  })
}

pub fn call_field(
  environment: Environment,
  store: TypeStore,
  field: glance.Field(glance.Expression),
) -> error.TypeCheckResult(#(TypeStore, glance.Field(types.Type))) {
  case field {
    glance.LabelledField(label, arg_expr) ->
      expression(environment, store, arg_expr)
      |> result.map(fn(state) {
        let #(store, type_) = state
        #(store, glance.LabelledField(label, type_))
      })
    glance.UnlabelledField(arg_expr) ->
      expression(environment, store, arg_expr)
      |> result.map(fn(state) {
        let #(store, type_) = state
        #(store, glance.UnlabelledField(type_))
      })
    glance.ShorthandField(label) ->
      types.lookup_variable_type(environment, label)
      |> result.map(fn(type_) { #(store, glance.LabelledField(label, type_)) })
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
  case glimpse_target {
    types.CallableType(..) | types.GenericCallableType(..) -> {
      let #(store, parameters, labels, return) =
        types.instantiate_callable(store, glimpse_target)

      case parameters {
        [] -> Error(error.InvalidArguments("()", "a piped value"))
        [first_param, ..rest_params] -> {
          use store <- result.try(types.unify(
            store,
            environment,
            left_type,
            first_param,
          ))

          // The piped value occupies the first parameter position, so labels
          // must be re-indexed relative to the remaining parameters.
          let shifted_labels =
            dict.fold(labels, dict.new(), fn(acc, label, position) {
              case position {
                0 -> acc
                _ -> dict.insert(acc, label, position - 1)
              }
            })

          use #(store, _argument_types) <- result.try(check_arguments(
            environment,
            store,
            arguments,
            rest_params,
            shifted_labels,
          ))

          Ok(types.resolve(store, return))
        }
      }
    }
    _ -> Error(error.NotCallable(types.to_string(environment, glimpse_target)))
  }
}
