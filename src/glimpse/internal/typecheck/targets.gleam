import glance
import gleam/dict
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/set
import glimpse/error
import glimpse/internal/typecheck/types.{
  type CallTarget, type Environment, type TargetSupport,
}

/// The `@external` implementations a function declares, converted to target
/// support. A function with an external for a target runs on that target; the
/// erlang and javascript booleans are set independently.
pub fn external_support(
  definition: glance.Definition(glance.Function),
) -> TargetSupport {
  list.fold(
    definition.attributes,
    types.no_targets_supported(),
    fn(support, attribute) {
      case attribute.name == "external" {
        False -> support
        True ->
          case attribute.arguments {
            [glance.Variable(_, "erlang"), ..] ->
              types.TargetSupport(erlang: True, javascript: support.javascript)
            [glance.Variable(_, "javascript"), ..] ->
              types.TargetSupport(erlang: support.erlang, javascript: True)
            _ -> support
          }
      }
    },
  )
}

/// Whether a function declares at least one `@external` implementation. Such a
/// function uses the external where declared and, when it has no Gleam body, is
/// only usable on those targets.
fn has_external(definition: glance.Definition(glance.Function)) -> Bool {
  list.any(definition.attributes, fn(attribute) { attribute.name == "external" })
}

/// Whether a function has a Gleam body to run on targets without an external.
/// A function with an empty body (`{}`) and no externals is a pure function and
/// runs everywhere; a bodyless function is one with an empty body *and* an
/// external, whose external is its only implementation.
fn has_gleam_body(definition: glance.Definition(glance.Function)) -> Bool {
  definition.definition.body != [] || !has_external(definition)
}

/// Compute which targets every function of a module can run on, keyed by
/// definition name. Direct `@external` implementations are fixed; a Gleam body
/// additionally supports a target only when every function it calls supports
/// it. Cross-module callees resolve against the already-computed support of
/// the modules this module imports (processed first in dependency order), and
/// same-module callees are resolved by iterating to a fixpoint, starting
/// optimistically so pure-Gleam recursion stays supported.
pub fn compute_module_target_support(
  environment: Environment,
  functions: List(glance.Definition(glance.Function)),
) -> dict.Dict(String, TargetSupport) {
  let module_names =
    set.from_list(list.map(functions, fn(d) { d.definition.name }))

  // Start from the imported (unqualified) entries already merged in; they are
  // final and never iterated. Same-module functions start optimistically:
  // a function with a body initially supports every target and is narrowed by
  // its callees.
  let initial =
    list.fold(functions, environment.target_support, fn(acc, definition) {
      let direct = external_support(definition)
      let start = case has_gleam_body(definition) {
        True ->
          types.TargetSupport(
            erlang: direct.erlang || True,
            javascript: direct.javascript || True,
          )
        False -> direct
      }
      dict.insert(acc, definition.definition.name, start)
    })

  let max_iterations = list.length(functions) + 1
  let final =
    iterate(environment, functions, module_names, initial, max_iterations)
  // Keep imported entries that are not module functions.
  list.fold(functions, final, fn(acc, definition) {
    let name = definition.definition.name
    case dict.get(final, name) {
      Ok(support) -> dict.insert(acc, name, support)
      Error(_) -> acc
    }
  })
}

fn iterate(
  environment: Environment,
  functions: List(glance.Definition(glance.Function)),
  module_names: set.Set(String),
  estimates: dict.Dict(String, TargetSupport),
  remaining: Int,
) -> dict.Dict(String, TargetSupport) {
  case remaining {
    0 -> estimates
    _ -> {
      let next =
        list.fold(functions, estimates, fn(acc, definition) {
          let name = definition.definition.name
          let direct = external_support(definition)
          let support = case has_gleam_body(definition) {
            True -> {
              let body_support =
                body_callees(definition.definition)
                |> list.fold(types.TargetSupport(True, True), fn(acc, callee) {
                  let callee_support =
                    callee_support(environment, module_names, estimates, callee)
                  types.TargetSupport(
                    erlang: acc.erlang && callee_support.erlang,
                    javascript: acc.javascript && callee_support.javascript,
                  )
                })
              types.TargetSupport(
                erlang: direct.erlang || body_support.erlang,
                javascript: direct.javascript || body_support.javascript,
              )
            }
            False -> direct
          }
          dict.insert(acc, name, support)
        })
      case next == estimates {
        True -> next
        False ->
          iterate(environment, functions, module_names, next, remaining - 1)
      }
    }
  }
}

/// The targets a single callee supports: a same-module function uses the
/// running fixpoint estimate, an imported function its defining module's
/// computed support, and anything else (a parameter, constant, or lambda)
/// supports every target.
fn callee_support(
  environment: Environment,
  module_names: set.Set(String),
  estimates: dict.Dict(String, TargetSupport),
  callee: CallTarget,
) -> TargetSupport {
  case callee {
    types.Named(name) ->
      case set.contains(module_names, name) {
        True ->
          dict.get(estimates, name)
          |> result.unwrap(types.all_targets_supported())
        False -> types.definition_target_support(environment, name)
      }
    types.Namespaced(container, name) ->
      case module_path_of(environment, container) {
        option.None -> types.all_targets_supported()
        option.Some(module_path) ->
          case dict.get(environment.imports.module_environments, module_path) {
            Error(_) -> types.all_targets_supported()
            Ok(module_env) -> types.definition_target_support(module_env, name)
          }
      }
  }
}

/// The absolute module path a local namespace name refers to, by reversing the
/// import-name mapping (which records `absolute -> local alias`).
fn module_path_of(
  environment: Environment,
  container: String,
) -> Option(String) {
  case
    list.find(dict.to_list(environment.imports.import_names), fn(pair) {
      let #(_module, relative) = pair
      relative == container
    })
  {
    Error(_) -> option.None
    Ok(#(module, _relative)) -> option.Some(module)
  }
}

/// The named functions a function body invokes. Only invocations constrain
/// target support (a bare function reference can simply never be called on a
/// given target); recursion into nested lambdas, case clauses, and blocks
/// counts, since those calls run as part of this function's execution.
fn body_callees(function: glance.Function) -> List(CallTarget) {
  statement_callees(function.body)
}

fn statement_callees(statements: List(glance.Statement)) -> List(CallTarget) {
  list.flatten(list.map(statements, statement_callee))
}

fn statement_callee(statement: glance.Statement) -> List(CallTarget) {
  case statement {
    glance.Use(_, _, function) -> expression_callees(function)
    glance.Assignment(_, _, _, _, value) -> expression_callees(value)
    glance.Assert(_, expression, message) ->
      list.append(expression_callees(expression), case message {
        option.None -> []
        option.Some(message_expression) ->
          expression_callees(message_expression)
      })
    glance.Expression(expression) -> expression_callees(expression)
  }
}

fn expression_callees(expression: glance.Expression) -> List(CallTarget) {
  case expression {
    glance.Int(..)
    | glance.Float(..)
    | glance.String(..)
    | glance.Variable(..) -> []
    glance.NegateInt(_, value) | glance.NegateBool(_, value) ->
      expression_callees(value)
    glance.Block(_, statements) -> statement_callees(statements)
    glance.Panic(_, message) | glance.Todo(_, message) ->
      case message {
        option.None -> []
        option.Some(message_expression) ->
          expression_callees(message_expression)
      }
    glance.Tuple(_, elements) ->
      list.flatten(list.map(elements, expression_callees))
    glance.List(_, elements, rest) ->
      list.append(
        list.flatten(list.map(elements, expression_callees)),
        case rest {
          option.None -> []
          option.Some(rest_expression) -> expression_callees(rest_expression)
        },
      )
    glance.Fn(_, _, _, body) -> statement_callees(body)
    glance.RecordUpdate(_, _, _, record, fields) ->
      list.append(
        expression_callees(record),
        list.flatten(
          list.map(fields, fn(field) {
            expression_callees(record_update_field_expression(field))
          }),
        ),
      )
    glance.FieldAccess(_, container, _) -> expression_callees(container)
    glance.Call(_, target, arguments) ->
      list.append(
        call_target_callees(target),
        list.append(
          expression_callees(target),
          list.flatten(
            list.map(arguments, fn(field) {
              expression_callees(field_expression(field))
            }),
          ),
        ),
      )
    glance.TupleIndex(_, tuple, _) -> expression_callees(tuple)
    glance.FnCapture(_, _, function, arguments_before, arguments_after) ->
      list.append(
        call_target_callees(function),
        list.append(
          expression_callees(function),
          list.flatten(
            list.map(list.append(arguments_before, arguments_after), fn(field) {
              expression_callees(field_expression(field))
            }),
          ),
        ),
      )
    glance.BitString(_, segments) ->
      list.flatten(
        list.map(segments, fn(segment) {
          let #(value, _options) = segment
          expression_callees(value)
        }),
      )
    glance.Case(_, subjects, clauses) ->
      list.append(
        list.flatten(list.map(subjects, expression_callees)),
        list.flatten(
          list.map(clauses, fn(clause) {
            list.append(
              case clause.guard {
                option.None -> []
                option.Some(guard) -> expression_callees(guard)
              },
              expression_callees(clause.body),
            )
          }),
        ),
      )
    glance.BinaryOperator(_, operator, left, right) -> {
      let left_callees = expression_callees(left)
      let right_callees = case operator {
        glance.Pipe -> invoked_expression_callees(right)
        _ -> expression_callees(right)
      }
      list.append(left_callees, right_callees)
    }
    glance.Echo(_, echoed, message) ->
      list.append(
        case echoed {
          option.None -> []
          option.Some(echoed_expression) ->
            expression_callees(echoed_expression)
        },
        case message {
          option.None -> []
          option.Some(message_expression) ->
            expression_callees(message_expression)
        },
      )
  }
}

/// The callees of the right side of a pipe, which is invoked with the piped
/// value: `x |> f` invokes `f`, `x |> f(a)` invokes `f`, and `x |> f(_, a)`
/// invokes `f`.
fn invoked_expression_callees(
  expression: glance.Expression,
) -> List(CallTarget) {
  case expression {
    glance.Call(_, target, arguments) ->
      list.append(
        call_target_callees(target),
        list.flatten(
          list.map(arguments, fn(field) {
            expression_callees(field_expression(field))
          }),
        ),
      )
    glance.FnCapture(_, _, function, arguments_before, arguments_after) ->
      list.append(
        call_target_callees(function),
        list.flatten(
          list.map(list.append(arguments_before, arguments_after), fn(field) {
            expression_callees(field_expression(field))
          }),
        ),
      )
    _ -> expression_callees(expression)
  }
}

/// The named function a call target invokes, when it is a direct reference.
fn call_target_callees(target: glance.Expression) -> List(CallTarget) {
  case target {
    glance.Variable(_, name) -> [types.Named(name)]
    glance.FieldAccess(_, glance.Variable(_, container), label) -> [
      types.Namespaced(container, label),
    ]
    _ -> []
  }
}

fn field_expression(
  field: glance.Field(glance.Expression),
) -> glance.Expression {
  case field {
    glance.UnlabelledField(expression) -> expression
    glance.LabelledField(_, _, expression) -> expression
    glance.ShorthandField(_, _) -> glance.Int(glance.Span(-1, -1), "0")
  }
}

fn record_update_field_expression(
  field: glance.RecordUpdateField(glance.Expression),
) -> glance.Expression {
  case field.item {
    option.None -> glance.Int(glance.Span(-1, -1), "0")
    option.Some(expression) -> expression
  }
}

/// Report a use of a function that cannot run on the active build target, e.g.
/// calling `gleam/erlang`'s `reference.new` from javascript-target code. Only
/// enforced when the module being checked is the package's own code, matching
/// the real compiler's target-support handling for dependencies.
pub fn check_callee(
  environment: Environment,
  target_expression: glance.Expression,
) -> Result(Nil, error.TypeCheckError) {
  case environment.check_target_support {
    False -> Ok(Nil)
    True ->
      case callee_definition_support(environment, target_expression) {
        option.None -> Ok(Nil)
        option.Some(#(name, support)) ->
          case types.target_supports(environment.target, support) {
            True -> Ok(Nil)
            False -> Error(error.UnsupportedTarget(name))
          }
      }
  }
}

/// The name and target support of the function a call target references, when
/// it resolves to a known definition. `option.None` means the target is not a
/// direct function reference (a lambda, a local value, an arbitrary
/// expression), which is never checked here.
fn callee_definition_support(
  environment: Environment,
  target_expression: glance.Expression,
) -> Option(#(String, TargetSupport)) {
  case target_expression {
    glance.Variable(_, name) ->
      option.Some(#(name, types.definition_target_support(environment, name)))
    glance.FieldAccess(_, glance.Variable(_, container), label) ->
      case module_path_of(environment, container) {
        option.None -> option.None
        option.Some(module_path) ->
          case dict.get(environment.imports.module_environments, module_path) {
            Error(_) -> option.None
            Ok(module_env) ->
              option.Some(#(
                label,
                types.definition_target_support(module_env, label),
              ))
          }
      }
    _ -> option.None
  }
}
