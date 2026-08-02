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
  type Environment, type Type, type TypeResult, type TypeStateResult,
  type TypeStore,
}

/// Typecheck a sequence of statements, threading the environment through each
/// one. Returns the type of the final statement, or Nil if the block is empty.
pub fn block(
  environment: Environment,
  statements: List(glance.Statement),
) -> TypeStateResult {
  list.fold_until(
    statements,
    Ok(types.EnvState(environment, types.NilType)),
    fn(state, stmnt) {
      case state {
        Error(_) -> list.Stop(state)
        Ok(type_out) -> list.Continue(statement(type_out.environment, stmnt))
      }
    },
  )
}

/// Typecheck a single statement, returning the updated environment and the
/// statement's type.
pub fn statement(
  environment: Environment,
  statement: glance.Statement,
) -> TypeStateResult {
  case statement {
    glance.Expression(expr) ->
      expression(environment, expr)
      |> result.map(types.EnvState(environment, _))

    glance.Assignment(_, kind, pat, annotation, value_expression) -> {
      let value_type_result = expression(environment, value_expression)

      let annotated_type_result = case annotation {
        option.None -> Ok(option.None)
        option.Some(annotation) ->
          types.type_(environment, annotation)
          |> result.map(option.Some)
      }

      use annotated_type <- result.try(annotated_type_result)
      use value_type <- result.try(value_type_result)

      let checked_type = case annotated_type {
        option.Some(annotated) -> {
          let store = types.new_type_store()
          types.unify(store, environment, value_type, annotated)
          |> result.map(fn(_) { annotated })
          |> result.map_error(fn(_) {
            error.InvalidAnnotation(
              types.to_string(environment, value_type),
              types.to_string(environment, annotated),
              type_name(pat),
            )
          })
        }
        option.None -> Ok(value_type)
      }

      use type_ <- result.try(checked_type)

      case kind {
        glance.Let -> {
          use env <- result.try(pattern.typecheck_pattern(
            environment,
            type_,
            pat,
          ))
          Ok(types.EnvState(env, type_))
        }
        glance.LetAssert(_) -> {
          use env <- result.try(pattern.typecheck_pattern(
            environment,
            type_,
            pat,
          ))
          Ok(types.EnvState(env, types.NilType))
        }
      }
    }

    glance.Assert(_, expression_, _message) -> {
      use type_ <- result.try(expression(environment, expression_))
      case type_ {
        types.BoolType -> Ok(types.EnvState(environment, types.NilType))
        _ ->
          Error(error.InvalidType(
            types.to_string(environment, type_),
            "Bool",
            "the assert statement requires a Bool",
          ))
      }
    }

    glance.Use(_, patterns, function_expr) ->
      use_statement(environment, patterns, function_expr)
  }
}

fn type_name(pat: glance.Pattern) -> String {
  case pat {
    glance.PatternVariable(_, name) -> name
    glance.PatternDiscard(_, name) -> name
    _ -> ""
  }
}

/// Typecheck a `use` statement. The use function must be a callable whose last
/// parameter is itself a function that takes the bound variables as arguments.
/// The result of the use expression is the return type of that inner function.
fn use_statement(
  environment: Environment,
  patterns: List(glance.UsePattern),
  function_expr: glance.Expression,
) -> TypeStateResult {
  case function_expr {
    glance.Call(_, target, arguments) ->
      use_call(environment, patterns, target, arguments)
    _ -> use_statement_with_type(environment, patterns, function_expr)
  }
}

/// Typecheck a `use` statement where the function is a call, e.g.
/// `use y <- with_x(10)`. The given arguments are checked against all but the
/// last parameter of the function; the last parameter is the callback that the
/// `use` expression provides.
fn use_call(
  environment: Environment,
  patterns: List(glance.UsePattern),
  target: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
) -> TypeStateResult {
  use glimpse_target <- result.try(expression(environment, target))
  use argument_fields <- result.try(
    arguments |> list.map(call_field(environment, _)) |> result.all,
  )

  case glimpse_target {
    types.CallableType(..) | types.GenericCallableType(..) -> {
      let #(store, parameters, labels, _) =
        types.instantiate_callable(types.new_type_store(), glimpse_target)

      use types.EnvState(env, callback_return) <- result.try(fold_use_patterns(
        environment,
        patterns,
        parameters,
      ))

      let given_parameters =
        list.take(parameters, up_to: list.length(parameters) - 1)

      use positioned_arguments <- result.try(functions.order_call_arguments(
        environment,
        argument_fields,
        given_parameters,
        labels,
      ))

      let store_result =
        list.try_fold(
          list.zip(positioned_arguments, given_parameters),
          store,
          fn(store, pair) {
            let #(arg_type, param_type) = pair
            types.unify(store, environment, arg_type, param_type)
          },
        )
        |> result.map_error(fn(_) {
          error.InvalidArguments(
            "(" <> types.list_to_string(given_parameters, environment) <> ")",
            "("
              <> types.list_to_string(positioned_arguments, environment)
              <> ")",
          )
        })

      use store <- result.try(store_result)

      let #(_, resolved_callback_return) = types.resolve(store, callback_return)
      Ok(types.EnvState(env, types.generalise(store, resolved_callback_return)))
    }
    _ -> Error(error.NotCallable(types.to_string(environment, glimpse_target)))
  }
}

/// Typecheck a `use` statement whose function is a bare name or other
/// non-call expression, e.g. `use value <- maybe`. The whole expression must be
/// a callable taking the use patterns plus a callback.
fn use_statement_with_type(
  environment: Environment,
  patterns: List(glance.UsePattern),
  function_expr: glance.Expression,
) -> TypeStateResult {
  use target_type <- result.try(expression(environment, function_expr))

  case target_type {
    types.CallableType(parameters, _, _)
    | types.GenericCallableType(parameters, _, _, _) ->
      fold_use_patterns(environment, patterns, parameters)
    _ -> Error(error.NotCallable(types.to_string(environment, target_type)))
  }
}

/// The parameters given to a `use` statement must be the number of patterns
/// plus one callback parameter. This checks that, extracts the callback's
/// parameter types and return type, and folds the use patterns against the
/// callback's parameter types.
fn fold_use_patterns(
  environment: Environment,
  patterns: List(glance.UsePattern),
  parameters: List(types.Type),
) -> TypeStateResult {
  case list.length(parameters) == list.length(patterns) + 1 {
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
            environment,
            fn(env, pair) {
              let #(use_pattern, type_) = pair
              pattern.typecheck_pattern(env, type_, use_pattern.pattern)
            },
          )
          |> result.map(fn(env) { types.EnvState(env, callback_return) })
      }
    }
  }
}

/// Typecheck an expression and return its type.
pub fn expression(
  environment: Environment,
  expr: glance.Expression,
) -> TypeResult {
  case expr {
    glance.Int(_, _) -> Ok(types.IntType)
    glance.Float(_, _) -> Ok(types.FloatType)
    glance.String(_, _) -> Ok(types.StringType)
    glance.Variable(_, "Nil") -> Ok(types.NilType)
    glance.Variable(_, "True") | glance.Variable(_, "False") ->
      Ok(types.BoolType)
    glance.Variable(_, name) -> types.lookup_variable_type(environment, name)

    glance.NegateInt(_, int_expr) ->
      expression(environment, int_expr)
      |> result.try(fn(got) {
        case got {
          types.IntType -> Ok(types.IntType)
          _ ->
            Error(error.InvalidType(
              types.to_string(environment, got),
              "Int",
              "- can only negate Int",
            ))
        }
      })

    glance.NegateBool(_, bool_expr) ->
      expression(environment, bool_expr)
      |> result.try(fn(got) {
        case got {
          types.BoolType -> Ok(types.BoolType)
          _ ->
            Error(error.InvalidType(
              types.to_string(environment, got),
              "Bool",
              "! can only negate Bool",
            ))
        }
      })

    glance.Block(_, statements) ->
      block(environment, statements)
      |> result.map(fn(state) { state.state })

    glance.Panic(_, _) -> Ok(types.GenericTypeVariable("todo"))
    glance.Todo(_, _) -> Ok(types.GenericTypeVariable("todo"))

    glance.Tuple(_, elements) ->
      list.try_map(elements, expression(environment, _))
      |> result.map(types.TupleType)

    glance.TupleIndex(_, tuple_expr, index) -> {
      use tuple_type <- result.try(expression(environment, tuple_expr))
      case tuple_type {
        types.TupleType(elements) ->
          list.drop(elements, up_to: index)
          |> list.first
          |> result.replace_error(error.UnexpectedType(
            types.to_string(environment, tuple_type),
            "a tuple with an element at index " <> int.to_string(index),
          ))
        _ ->
          Error(error.UnexpectedType(
            types.to_string(environment, tuple_type),
            "a tuple",
          ))
      }
    }

    glance.List(_, elements, rest) ->
      list_expression(environment, elements, rest)

    glance.Fn(_, arguments, return_annotation, body) ->
      fn_literal(environment, arguments, return_annotation, body)

    glance.RecordUpdate(_, module, constructor, record, fields) ->
      record_update(environment, module, constructor, record, fields)

    glance.FieldAccess(_, container, label) -> {
      use container_expression_type <- result.try(expression(
        environment,
        container,
      ))
      case container_expression_type {
        types.NamespaceType(nested_defs, _nested_types) ->
          nested_defs
          |> dict.get(label)
          |> result.replace_error(error.InvalidName(label))
        type_ ->
          Error(error.InvalidFieldAccess(
            types.to_string(environment, type_),
            label,
          ))
      }
    }

    glance.Call(_, target, arguments) -> call(environment, target, arguments)

    glance.BinaryOperator(_, operator, left, right) ->
      binop(environment, operator, left, right)

    glance.BitString(_, segments) -> {
      list.try_map(segments, fn(segment) {
        let #(value_expr, _options) = segment
        expression(environment, value_expr)
      })
      |> result.map(fn(_) { types.BitArrayType })
    }

    glance.Case(_, subjects, clauses) ->
      case_expression(environment, subjects, clauses)

    glance.Echo(_, message) -> {
      case message {
        option.None -> Ok(types.NilType)
        option.Some(message_expr) ->
          expression(environment, message_expr)
          |> result.map(fn(_) { types.NilType })
      }
    }

    glance.FnCapture(_, label, function, arguments_before, arguments_after) -> {
      use target_type <- result.try(expression(environment, function))

      case target_type {
        types.CallableType(..) | types.GenericCallableType(..) -> {
          let #(store, parameters, labels, return) =
            types.instantiate_callable(types.new_type_store(), target_type)

          use typed_before <- result.try(
            arguments_before
            |> list.map(call_field(environment, _))
            |> result.all,
          )
          use typed_after <- result.try(
            arguments_after
            |> list.map(call_field(environment, _))
            |> result.all,
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
  elements: List(glance.Expression),
  rest: option.Option(glance.Expression),
) -> TypeResult {
  use element_types <- result.try(
    list.try_map(elements, expression(environment, _)),
  )

  let store = types.new_type_store()

  let element_type_result = case elements {
    [] -> {
      case rest {
        option.None -> Ok(types.GenericTypeVariable("todo"))
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
          |> result.map(fn(_) { first })
        [] -> Error(error.InvalidType("unknown", "List", "empty element types"))
      }
  }

  use element_type <- result.try(element_type_result)

  let element_type = case rest {
    option.None -> Ok(element_type)
    option.Some(rest_expr) -> {
      use rest_type <- result.try(expression(environment, rest_expr))
      case rest_type {
        types.ListType(rest_element) -> {
          let store = types.new_type_store()
          types.unify(store, environment, element_type, rest_element)
          |> result.map(fn(_) { element_type })
        }
        _ ->
          Error(error.InvalidType(
            types.to_string(environment, rest_type),
            "List(" <> types.to_string(environment, element_type) <> ")",
            "list rest must be a list",
          ))
      }
    }
  }

  use element_type <- result.try(element_type)
  Ok(types.ListType(element_type))
}

/// Typecheck a function literal. Parameters must be annotated (Gleam requires
/// annotations on anonymous function parameters). Returns a CallableType.
fn fn_literal(
  environment: Environment,
  arguments: List(glance.FnParameter),
  return_annotation: option.Option(glance.Type),
  body: List(glance.Statement),
) -> TypeResult {
  use param_types <- result.try(
    list.try_map(arguments, fn(param) {
      case param {
        glance.FnParameter(_, type_: option.Some(annotation)) ->
          types.type_(environment, annotation)
        glance.FnParameter(_, type_: option.None) ->
          Error(error.MissingParameterAnnotation("anonymous function"))
      }
    }),
  )

  use param_env <- result.try(
    list.try_fold(list.zip(arguments, param_types), environment, fn(env, pair) {
      let #(param, type_) = pair
      case param {
        glance.FnParameter(glance.Named(name), _) ->
          Ok(types.add_or_update_def_in_env(env, name, type_))
        glance.FnParameter(glance.Discarded(_), _) -> Ok(env)
      }
    }),
  )

  use body_out <- result.try(block(param_env, body))

  let inferred_return = body_out.state

  let return_type_result = case return_annotation {
    option.None -> Ok(inferred_return)
    option.Some(annotation) -> {
      use annotated <- result.try(types.type_(environment, annotation))
      let store = types.new_type_store()
      types.unify(store, environment, inferred_return, annotated)
      |> result.map(fn(_) { annotated })
      |> result.map_error(fn(_) {
        error.InvalidReturnType(
          "anonymous function",
          types.to_string(environment, inferred_return),
          types.to_string(environment, annotated),
        )
      })
    }
  }

  use return_type <- result.try(return_type_result)
  Ok(types.CallableType(param_types, dict.new(), return_type))
}

/// Typecheck a record update expression (`Type(..record, field: value)`).
/// The record must already be bound to a variable of the custom type.
fn record_update(
  environment: Environment,
  module: option.Option(String),
  constructor: String,
  record: glance.Expression,
  fields: List(glance.RecordUpdateField(glance.Expression)),
) -> TypeResult {
  use record_type <- result.try(expression(environment, record))

  let constructor_lookup = case module {
    option.None ->
      dict.get(environment.definitions, constructor)
      |> result.replace_error(error.InvalidName(constructor))
    option.Some(module_name) -> {
      case dict.get(environment.definitions, module_name) {
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
        types.instantiate_callable(types.new_type_store(), constructor_type)

      use store <- result.try(types.unify(
        store,
        environment,
        record_type,
        constructor_return,
      ))

      list.try_fold(fields, environment, fn(env, field) {
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
            option.None -> Ok(env)
            option.Some(value_expr) -> {
              use value_type <- result.try(expression(env, value_expr))
              let store = types.new_type_store()
              types.unify(store, env, value_type, expected_type)
              |> result.map(fn(_) { env })
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
      |> result.map(fn(_) { record_type })
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
  subjects: List(glance.Expression),
  clauses: List(glance.Clause),
) -> TypeResult {
  use subject_types <- result.try(
    list.try_map(subjects, expression(environment, _)),
  )

  case clauses {
    [] -> Error(error.CaseClauseMismatch("no clauses", "any"))
    [first_clause, ..] -> {
      use first_body_type <- result.try(clause_body_type(
        environment,
        subject_types,
        first_clause,
      ))

      let remaining_types =
        list.map(list.drop(clauses, up_to: 1), fn(clause) {
          clause_body_type(environment, subject_types, clause)
        })

      result.all(remaining_types)
      |> result.try(fn(clause_types) {
        let store = types.new_type_store()
        list.try_fold(clause_types, store, fn(store, clause_type) {
          types.unify(store, environment, first_body_type, clause_type)
        })
        |> result.map(fn(_) { first_body_type })
      })
    }
  }
}

fn clause_body_type(
  environment: Environment,
  subject_types: List(Type),
  clause: glance.Clause,
) -> TypeResult {
  use pattern_env <- result.try(
    list.try_fold(
      list.zip(subject_types, clause.patterns),
      environment,
      fn(env, pair) {
        let #(subject_type, patterns) = pair
        list.try_fold(patterns, env, fn(env, pattern) {
          pattern.typecheck_pattern(env, subject_type, pattern)
        })
      },
    ),
  )

  use guard_type <- result.try(case clause.guard {
    option.None -> Ok(types.BoolType)
    option.Some(guard_expr) -> expression(pattern_env, guard_expr)
  })

  case guard_type {
    types.BoolType -> expression(pattern_env, clause.body)
    _ -> Error(error.InvalidGuard(types.to_string(pattern_env, guard_type)))
  }
}

/// Typecheck a function call. The target is typechecked, instantiated (so
/// generic parameters become fresh variables), arguments are ordered to match
/// the target's parameter positions, and each is unified with its parameter
/// type. The return type is resolved and any remaining variables are
/// generalised back to named generic variables.
pub fn call(
  environment: Environment,
  target: glance.Expression,
  arguments: List(glance.Field(glance.Expression)),
) -> TypeResult {
  let glimpse_argument_fields_result =
    arguments
    |> list.map(call_field(environment, _))
    |> result.all

  use glimpse_target <- result.try(expression(environment, target))
  use glimpse_argument_fields <- result.try(glimpse_argument_fields_result)

  case glimpse_target {
    types.CallableType(target_arguments, _, _)
    | types.GenericCallableType(target_arguments, _, _, _) -> {
      let #(store, parameters, labels, return) =
        types.instantiate_callable(types.new_type_store(), glimpse_target)

      use positioned_arguments <- result.try(functions.order_call_arguments(
        environment,
        glimpse_argument_fields,
        target_arguments,
        labels,
      ))

      let store_result =
        list.try_fold(
          list.zip(positioned_arguments, parameters),
          store,
          fn(store, pair) {
            let #(arg_type, param_type) = pair
            types.unify(store, environment, arg_type, param_type)
          },
        )
        |> result.map_error(fn(_) {
          let expected =
            "(" <> types.list_to_string(target_arguments, environment) <> ")"
          let actual =
            "("
            <> types.list_to_string(positioned_arguments, environment)
            <> ")"
          error.InvalidArguments(expected, actual)
        })

      use store <- result.try(store_result)

      let #(_, resolved_return) = types.resolve(store, return)
      Ok(types.generalise(store, resolved_return))
    }
    _ -> Error(error.NotCallable(types.to_string(environment, glimpse_target)))
  }
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
) -> TypeResult {
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
      let partial =
        types.CallableType(
          list.reverse(remaining_reversed),
          reindexed_labels,
          resolved_return,
        )
      Ok(types.generalise(store, partial))
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

pub fn call_field(
  environment: Environment,
  field: glance.Field(glance.Expression),
) -> error.TypeCheckResult(glance.Field(types.Type)) {
  case field {
    glance.LabelledField(label, arg_expr) ->
      expression(environment, arg_expr)
      |> result.map(glance.LabelledField(label, _))
    glance.UnlabelledField(arg_expr) ->
      expression(environment, arg_expr)
      |> result.map(glance.UnlabelledField)
    glance.ShorthandField(label) ->
      types.lookup_variable_type(environment, label)
      |> result.map(glance.LabelledField(label, _))
  }
}

/// Typecheck a binary operator expression. Equality operators return Bool
/// (after unifying both operands); Pipe is handled specially.
pub fn binop(
  environment: Environment,
  operator: glance.BinaryOperator,
  left: glance.Expression,
  right: glance.Expression,
) -> TypeResult {
  // TODO: I have a feeling precedence matters here. ;-)
  case operator {
    glance.Pipe -> pipe(environment, left, right)
    _ -> {
      use left_type <- result.try(expression(environment, left))
      use right_type <- result.try(expression(environment, right))

      case operator {
        glance.And | glance.Or -> {
          case left_type, right_type {
            types.BoolType, types.BoolType -> Ok(types.BoolType)
            _, _ ->
              types.to_binop_error(
                environment,
                operator_string(operator),
                left_type,
                right_type,
                "two Bools",
              )
          }
        }

        glance.Eq | glance.NotEq -> {
          let store = types.new_type_store()
          types.unify(store, environment, left_type, right_type)
          |> result.map(fn(_) { types.BoolType })
          |> result.map_error(fn(_) {
            error.InvalidBinOp(
              operator_string(operator),
              types.to_string(environment, left_type),
              types.to_string(environment, right_type),
              "same type",
            )
          })
        }

        glance.LtInt
        | glance.LtEqInt
        | glance.GtEqInt
        | glance.GtInt
        | glance.AddInt
        | glance.SubInt
        | glance.MultInt
        | glance.DivInt
        | glance.RemainderInt -> {
          case left_type, right_type {
            types.IntType, types.IntType -> Ok(types.IntType)
            _, _ ->
              types.to_binop_error(
                environment,
                operator_string(operator),
                left_type,
                right_type,
                "two Ints",
              )
          }
        }

        glance.LtFloat
        | glance.LtEqFloat
        | glance.GtEqFloat
        | glance.GtFloat
        | glance.AddFloat
        | glance.SubFloat
        | glance.MultFloat
        | glance.DivFloat -> {
          case left_type, right_type {
            types.FloatType, types.FloatType -> Ok(types.FloatType)
            _, _ ->
              types.to_binop_error(
                environment,
                operator_string(operator),
                left_type,
                right_type,
                "two Floats",
              )
          }
        }

        glance.Concatenate -> {
          case left_type, right_type {
            types.StringType, types.StringType -> Ok(types.StringType)
            _, _ ->
              types.to_binop_error(
                environment,
                "<>",
                left_type,
                right_type,
                "two Strings",
              )
          }
        }

        glance.Pipe -> pipe(environment, left, right)
      }
    }
  }
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
  left: glance.Expression,
  right: glance.Expression,
) -> TypeResult {
  use left_type <- result.try(expression(environment, left))

  case right {
    glance.Call(_, target, arguments) -> {
      use glimpse_target <- result.try(expression(environment, target))
      pipe_value_into_callable(
        environment,
        left_type,
        glimpse_target,
        arguments,
      )
    }
    _ -> {
      use glimpse_target <- result.try(expression(environment, right))
      pipe_value_into_callable(environment, left_type, glimpse_target, [])
    }
  }
}

/// Unify the piped value with the first parameter of a callable and check any
/// remaining arguments against the remaining parameters, returning the resolved
/// and generalised return type.
fn pipe_value_into_callable(
  environment: Environment,
  left_type: Type,
  glimpse_target: Type,
  arguments: List(glance.Field(glance.Expression)),
) -> TypeResult {
  case glimpse_target {
    types.CallableType(..) | types.GenericCallableType(..) -> {
      let #(store, parameters, labels, return) =
        types.instantiate_callable(types.new_type_store(), glimpse_target)

      case parameters {
        [] -> Error(error.InvalidArguments("()", "a piped value"))
        [first_param, ..rest_params] -> {
          use store <- result.try(types.unify(
            store,
            environment,
            left_type,
            first_param,
          ))

          let argument_fields =
            arguments
            |> list.map(call_field(environment, _))
            |> result.all

          use argument_fields <- result.try(argument_fields)

          use positioned <- result.try(functions.order_call_arguments(
            environment,
            argument_fields,
            rest_params,
            labels,
          ))

          use store <- result.try(
            list.try_fold(
              list.zip(positioned, rest_params),
              store,
              fn(store, pair) {
                let #(arg_type, param_type) = pair
                types.unify(store, environment, arg_type, param_type)
              },
            ),
          )

          let #(_, resolved_return) = types.resolve(store, return)
          Ok(types.generalise(store, resolved_return))
        }
      }
    }
    _ -> Error(error.NotCallable(types.to_string(environment, glimpse_target)))
  }
}
