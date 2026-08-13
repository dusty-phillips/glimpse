import glance
import gleam/dict
import gleam/list
import gleam/option
import glimpse/error
import glimpse/internal/typecheck/types
import typecheck/helpers

const unknown_span = glance.Span(-1, -1)

pub fn todo_return_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { todo }")

  assert function_out.return
    == option.Some(glance.VariableType(unknown_span, "todo"))
}

pub fn panic_return_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { panic }")

  assert function_out.return
    == option.Some(glance.VariableType(unknown_span, "todo"))
}

/// Piping a value into `todo`/`panic` desugars to a wildcard call accepting any
/// piped value and arguments, so it must not be treated as an uncallable value.
pub fn pipe_into_todo_test() {
  helpers.ok_function_typecheck("fn foo(x: Int) -> Int { x |> todo }")
}

pub fn pipe_into_todo_with_message_test() {
  helpers.ok_function_typecheck("fn foo(x: Int) -> Int { x |> todo(\"msg\") }")
}

pub fn pipe_into_panic_test() {
  helpers.ok_function_typecheck("fn foo(x: Int) -> Int { x |> panic }")
}

/// `todo`/`panic` expect no labels, so a labelled argument is rejected both
/// directly and via a pipe.
pub fn labelled_argument_to_todo_is_rejected_test() {
  let err = helpers.error_function_typecheck("fn foo() -> Int { todo(foo: 1) }")
  assert err == error.UnexpectedLabelledArgument("foo")
}

pub fn labelled_argument_to_todo_via_pipe_is_rejected_test() {
  let err =
    helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { x |> todo(foo: 1) }",
    )
  assert err == error.UnexpectedLabelledArgument("foo")
}

pub fn labelled_argument_to_panic_is_rejected_test() {
  let err =
    helpers.error_function_typecheck("fn foo() -> Int { panic(foo: 1) }")
  assert err == error.UnexpectedLabelledArgument("foo")
}

pub fn tuple_return_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> #(Int, String) { #(1, \"a\") }")

  assert function_out.return
    == option.Some(
      glance.TupleType(glance.Span(12, 26), [
        glance.NamedType(glance.Span(14, 17), "Int", option.None, []),
        glance.NamedType(glance.Span(19, 25), "String", option.None, []),
      ]),
    )
}

pub fn tuple_index_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> Int { #(1, \"a\").0 }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn tuple_index_second_element_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> String { #(1, \"a\").1 }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 18), "String", option.None, []),
    )
}

pub fn tuple_index_out_of_range_test() {
  assert helpers.error_function_typecheck("fn foo() -> Int { #(1, \"a\").2 }")
    == error.UnexpectedType(
      "(Int, String)",
      "a tuple with an element at index 2",
    )
}

pub fn tuple_index_on_non_tuple_test() {
  assert helpers.error_function_typecheck("fn foo(x: Int) -> Int { x.0 }")
    == error.UnexpectedType("Int", "a tuple with an element at index 0")
}

pub fn tuple_index_on_unknown_type_test() {
  let got =
    helpers.error_function_typecheck(
      "fn foo() {
    let z = todo
    fn(x) { x.2 }(z)
  }",
    )
  let message = case got {
    error.UnexpectedType(_, message) -> message
    _ -> "unexpected error"
  }
  assert "a tuple with an element at index 2" == message
}

pub fn tuple_index_beyond_inferred_tuple_arity_is_rejected_test() {
  // Indexing a polymorphic function's result beyond the tuple's known arity
  // is an out-of-bounds error: the real compiler rejects `id(#(1, 2)).2`
  // rather than growing the (immutable) tuple.
  let got =
    helpers.error_module_typecheck(
      "pub fn id(x: a) -> a { x }
  pub fn foo() -> Int { id(#(1, 2)).2 }",
    )
  assert got
    == error.UnexpectedType("var_0", "a tuple with an element at index 2")
}

pub fn tuple_index_within_inferred_tuple_arity_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn pair(x: a, y: b) -> #(a, b) { #(x, y) }
  pub fn foo() -> Int {
    let t = pair(1, 2)
    t.0 + t.1
  }",
  )
}

pub fn list_infer_return_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { [1, 2, 3] }")

  assert function_out.return
    == option.Some(
      glance.NamedType(unknown_span, "List", option.None, [
        glance.NamedType(unknown_span, "Int", option.None, []),
      ]),
    )
}

pub fn mixed_list_error_test() {
  assert helpers.error_function_typecheck("fn foo() { [1, \"a\"] }")
    == error.InvalidType("Int", "String", "in type mismatch")
}

pub fn bit_array_return_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> BitArray { <<1, 2>> }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 20), "BitArray", option.None, []),
    )
}

pub fn bit_string_return_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> BitArray { <<1>> }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 20), "BitArray", option.None, []),
    )
}

pub fn bit_string_utf8_segment_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> BitArray { <<\"abc\":utf8>> }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 20), "BitArray", option.None, []),
    )
}

pub fn anonymous_fn_return_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() { fn(x: Int) { x + 1 } }")

  assert function_out.return
    == option.Some(glance.FunctionType(
      unknown_span,
      [glance.NamedType(unknown_span, "Int", option.None, [])],
      glance.NamedType(unknown_span, "Int", option.None, []),
    ))
}

pub fn anonymous_fn_missing_annotation_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { fn(x) { x } }")

  // The anonymous function's parameter should be inferred as a generic type variable
  assert function_out.return
    == option.Some(glance.FunctionType(
      unknown_span,
      [glance.VariableType(unknown_span, "a")],
      glance.VariableType(unknown_span, "a"),
    ))
}

pub fn record_update_test() {
  helpers.ok_module_typecheck(
    "pub type Person {
    Person(name: String, age: Int)
  }
  fn update(p: Person) -> Person {
    Person(..p, age: 30)
  }",
  )
}

pub fn record_update_wrong_field_type_test() {
  assert helpers.error_module_typecheck(
      "pub type Person {
    Person(name: String, age: Int)
  }
  fn update(p: Person) -> Person {
    Person(..p, age: \"thirty\")
  }",
    )
    == error.InvalidType("String", "Int", "in record update of field age")
}

pub fn parametric_record_update_test() {
  helpers.ok_module_typecheck(
    "type Box(a) { Box(value: a) }
  fn update(b: Box(Int)) -> Box(Int) {
    Box(..b, value: 30)
  }",
  )
}

pub fn parametric_record_update_wrong_field_type_test() {
  assert helpers.error_module_typecheck(
      "type Box(a) { Box(value: a) }
  fn update(b: Box(Int)) -> Box(Int) {
    Box(..b, value: \"thirty\")
  }",
    )
    == error.InvalidReturnType(
      "update",
      "main_module.Box(String)",
      "main_module.Box(Int)",
    )
}

pub fn assert_bool_returns_nil_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { assert 1 == 1 }")

  assert function_out.return
    == option.Some(glance.NamedType(unknown_span, "Nil", option.None, []))
}

pub fn assert_non_bool_error_test() {
  assert helpers.error_function_typecheck("fn foo() { assert 5 }")
    == error.InvalidType("Int", "Bool", "the assert statement requires a Bool")
}

pub fn block_expression_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { { 1 } }")

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn block_last_statement_type_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo() -> Int {
    1
    2}",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn case_multiple_clauses_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> String { case x { 1 -> \"one\" _ -> \"other\" } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(18, 24), "String", option.None, []),
    )
}

pub fn case_guard_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> Int { case x { 1 if x == 1 -> 1 _ -> 0 } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(18, 21), "Int", option.None, []),
    )
}

pub fn case_invalid_guard_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { 1 if x + 1 -> 1 _ -> 0 } }",
    )
    == error.InvalidGuard("Int")
}

pub fn guard_function_call_rejected_test() {
  assert helpers.error_module_typecheck(
      "fn pos(x: Int) -> Bool { x > 0 } fn foo(x: Int) -> Int { case x { y if pos(y) -> 0 _ -> 1 } }",
    )
    == error.InvalidGuardExpression
}

pub fn guard_pipeline_rejected_test() {
  assert helpers.error_module_typecheck(
      "fn pos(x: Int) -> Bool { x > 0 } fn foo(x: Int) -> Int { case x { y if y |> pos -> 0 _ -> 1 } }",
    )
    == error.InvalidGuardExpression
}

pub fn guard_case_expression_rejected_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { y if case y { 1 -> True _ -> False } -> 0 _ -> 1 } }",
    )
    == error.InvalidGuardExpression
}

pub fn guard_panic_rejected_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { y if panic -> 0 _ -> 1 } }",
    )
    == error.InvalidGuardExpression
}

pub fn guard_unary_minus_rejected_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { y if -y > 0 -> 0 _ -> 1 } }",
    )
    == error.InvalidGuardExpression
}

pub fn guard_todo_rejected_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { y if todo -> 0 _ -> 1 } }",
    )
    == error.TodoInConstant
}

pub fn guard_negative_literal_allowed_test() {
  let _ =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> Int { case x { y if y > -1 -> 0 _ -> 1 } }",
    )
}

pub fn guard_block_allowed_test() {
  let _ =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> Int { case x { y if { y > 0 } -> 0 _ -> 1 } }",
    )
}

pub fn guard_record_construction_allowed_test() {
  let _ =
    helpers.ok_module_typecheck(
      "type Rec { Rec(a: Int, b: Int) } fn foo(x: Rec) -> Int { case x { y if y == Rec(1, 2) -> 0 _ -> 1 } }",
    )
}

pub fn guard_tuple_literal_allowed_test() {
  let _ =
    helpers.ok_function_typecheck(
      "fn foo(x: #(Int, Int)) -> Int { case x { y if y == #(1, 2) -> 0 _ -> 1 } }",
    )
}

pub fn guard_list_literal_allowed_test() {
  let _ =
    helpers.ok_function_typecheck(
      "fn foo(x: List(Int)) -> Int { case x { y if y == [1, 2] -> 0 _ -> 1 } }",
    )
}

pub fn guard_field_access_allowed_test() {
  let _ =
    helpers.ok_function_typecheck(
      "fn foo(x: #(Int, Int)) -> Int { case x { y if y.0 == 1 -> 0 _ -> 1 } }",
    )
}

pub fn guard_bool_negation_allowed_test() {
  let _ =
    helpers.ok_function_typecheck(
      "fn foo(x: Bool) -> Int { case x { y if !y -> 0 _ -> 1 } }",
    )
}

pub fn guard_int_negation_rejected_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { y if !y == 1 -> 0 _ -> 1 } }",
    )
    == error.InvalidType("Int", "Bool", "! can only negate Bool")
}

pub fn guard_record_construction_labelled_argument_allowed_test() {
  let _ =
    helpers.ok_module_typecheck(
      "type Rec { Rec(a: Int) } fn foo(x: Rec) -> Int { case x { y if y == Rec(a: 1) -> 0 _ -> 1 } }",
    )
}

pub fn guard_record_construction_spread_rejected_test() {
  assert helpers.error_module_typecheck(
      "type Rec { Rec(a: Int) } fn foo(x: Rec) -> Int { case x { y if y == Rec(..z) -> 0 _ -> 1 } }",
    )
    == error.InvalidGuardExpression
}

pub fn guard_piped_function_literal_rejected_test() {
  assert helpers.error_module_typecheck(
      "fn foo(x: Int) -> Int { case x { y if y |> fn(a) { a } -> 0 _ -> 1 } }",
    )
    == error.InvalidGuardExpression
}

pub fn case_pattern_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> String { case x { \"a\" -> \"one\" _ -> \"other\" } }",
    )
    == error.PatternMismatch("string pattern", "String", "Int")
}

pub fn case_clause_body_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: Int) -> Int { case x { 1 -> 10 _ -> \"other\" } }",
    )
    == error.InvalidType("Int", "String", "in type mismatch")
}

pub fn case_pattern_variable_binds_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo(x: Int) -> Int { case x { 1 -> 1 y -> y } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(18, 21), "Int", option.None, []),
    )
}

pub fn case_tuple_pattern_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo() -> Int { case #(1, 2) { #(a, b) -> a } }",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn case_list_pattern_test() {
  assert helpers.error_function_typecheck(
      "fn foo() -> Int { case [1, 2] { [a, ..rest] -> a } }",
    )
    == error.InexhaustivePattern("[]")
}

pub fn use_statement_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn with_x(x: Int, f: fn(Int) -> Int) -> Int { f(x) }
    fn foo() -> Int {
      use y <- with_x(10)
      y + 1
    }",
    )

  let assert [foo_def, _] = module.module.functions
  assert foo_def.definition.return
    == option.Some(
      glance.NamedType(glance.Span(69, 72), "Int", option.None, []),
    )
}

pub fn use_wrong_pattern_count_test() {
  assert helpers.error_module_typecheck(
      "fn with_x(x: Int, f: fn(Int) -> Int) -> Int { f(x) }
    fn foo() -> Int {
      use a, b <- with_x(1)
      a
    }",
    )
    == error.InvalidUse(2)
}

pub fn pipe_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn add(a: Int, b: Int) -> Int { a + b }
    fn foo() -> Int { 1 |> add(2) }",
    )

  let assert [foo_def, _] = module.module.functions
  assert foo_def.definition.return
    == option.Some(
      glance.NamedType(glance.Span(56, 59), "Int", option.None, []),
    )
}

pub fn pipe_bare_function_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn double(x: Int) -> Int { x * 2 }
     fn foo() -> Int { 21 |> double }",
    )
  assert list.length(module.module.functions) == 2
}

pub fn pipe_to_non_callable_test() {
  assert helpers.error_function_typecheck("fn foo() -> Int { 1 |> 5 }")
    == error.NotCallable("Int")
}

pub fn pipe_type_mismatch_test() {
  assert helpers.error_module_typecheck(
      "fn double(x: Int) -> Int { x * 2 }
    fn foo() { \"s\" |> double }",
    )
    == error.InvalidType("String", "Int", "in type mismatch")
}

pub fn pipe_extra_args_test() {
  assert helpers.error_module_typecheck(
      "fn add(a: Int, b: Int) -> Int { a + b }
    fn foo() -> Int { 1 |> add(2, 3) }",
    )
    == error.InvalidArguments("()", "a piped value")
}

pub fn pipe_into_fn_literal_test() {
  // A function literal piped a value has its first parameter bound to the
  // piped value, so the callable shape must agree.
  let #(_module, _env) =
    helpers.ok_module_typecheck(
      "fn first(xs: List(a)) -> a {
        case xs {
          [x, ..] -> x
          [] -> panic
        }
      }
    fn foo(xs: List(Int)) -> Int {
      xs |> fn(x) { x } |> first
    }",
    )
}

pub fn pipe_into_fn_literal_arity_mismatch_test() {
  // A two-parameter function literal piped a single value has an unfilled
  // parameter, which the real compiler rejects.
  assert helpers.error_module_typecheck(
      "fn foo(xs: List(Int)) -> Int {
      xs |> fn(a, b) { a }
    }",
    )
    == error.InvalidReturnType("foo", "List(Int)", "Int")
}

pub fn let_bound_used_test() {
  let function_out =
    helpers.ok_function_typecheck(
      "fn foo() -> Int {
    let x = 5
    x}",
    )

  assert function_out.return
    == option.Some(
      glance.NamedType(glance.Span(12, 15), "Int", option.None, []),
    )
}

pub fn let_annotation_mismatch_test() {
  assert helpers.error_function_typecheck(
      "fn foo() {
    let x: String = 5
  }",
    )
    == error.InvalidAnnotation("Int", "String", "x")
}

pub fn zero_arg_variant_constructor_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "pub type Foo { Bar } pub fn main() -> Foo { Bar }",
    )
  assert dict.get(env.scope.definitions, "main")
    == Ok(types.CallableType(
      [],
      dict.new(),
      types.CustomType("main_module", "Foo", [], option.None),
    ))
}

pub fn invalid_escape_string_literal_test() {
  assert helpers.error_function_typecheck("fn foo() -> String { \"a\\1b\" }")
    == error.InvalidEscape("a\\1b")
}

pub fn invalid_escape_string_pattern_test() {
  assert helpers.error_function_typecheck(
      "fn foo(x: String) -> Int {
    case x {
      \"a\\1b\" -> 1
      _ -> 0
    }
  }",
    )
    == error.InvalidEscape("a\\1b")
}

pub fn invalid_escape_bit_string_test() {
  assert helpers.error_function_typecheck(
      "fn foo() -> BitArray { <<\"x\\1y\">> }",
    )
    == error.InvalidEscape("x\\1y")
}

pub fn record_update_keeps_distinct_signature_type_var_test() {
  assert helpers.error_module_typecheck(
      "pub type App(arguments, model, message) {
    App(
      arguments: arguments,
      model: model,
      message: message,
      name: String,
    )
  }
  fn named(app: App(arguments__zzz, model, message), name: String) -> App(arguments, model, message) {
    App(..app, name: name)
  }",
    )
    == error.InvalidReturnType(
      "named",
      "main_module.App(arguments__zzz, model, message)",
      "main_module.App(arguments, model, message)",
    )
}

pub fn record_update_may_change_type_parameter_field_test() {
  helpers.ok_module_typecheck(
    "type Box(a) { Box(value: a) }
  fn change_val(b: Box(Int), v: String) -> Box(String) {
    Box(..b, value: v)
  }",
  )
}

pub fn record_update_phantom_type_parameter_is_free_test() {
  helpers.ok_module_typecheck(
    "pub type Accepted
  pub type New
  pub type Snapshot(status) {
    Snapshot(title: String, content: String, info: Bool)
  }
  fn serialise(snapshot: Snapshot(New)) -> String {
    snapshot.title
  }
  fn accept(snapshot: Snapshot(Accepted), title: String) -> String {
    Snapshot(..snapshot, info: True) |> serialise
  }",
  )
}

pub fn record_update_nested_type_parameter_field_test() {
  helpers.ok_module_typecheck(
    "type Option(a) { None Some(a) }
  type Selector(message) { Selector }
  type Initialised(state, message, return) {
    Initialised(
      state: state,
      selector: Option(Selector(message)),
      result: return,
    )
  }
  fn with_selector(
    initialised: Initialised(state, message, return),
    selector: Selector(message),
  ) -> Initialised(state, message, return) {
    Initialised(..initialised, selector: Some(selector))
  }",
  )
}

pub fn unknown_external_target_test() {
  assert helpers.error_module_typecheck(
      "@external(rust, \"gleam@erlang@process\", \"send\")
  fn send(pid: BitArray) -> Nil {
    todo
  }",
    )
    == error.UnknownExternalTarget("rust")
}

pub fn valid_external_target_test() {
  helpers.ok_module_typecheck(
    "@external(erlang, \"gleam@erlang@process\", \"send\")
  fn send(pid: BitArray) -> Nil {
    todo
  }",
  )
}

pub fn undeclared_type_variable_in_custom_type_field_test() {
  assert helpers.error_module_typecheck(
      "pub type App(args, model) {
    App(update: fn(args) -> List(missing), view: model)
  }",
    )
    == error.UnknownCustomType("missing")
}

pub fn declared_type_variable_in_custom_type_field_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type App(args, model) {
    App(update: fn(args) -> List(args), view: model)
  }",
  )
}

pub fn unknown_attribute_test() {
  assert helpers.error_module_typecheck(
      "@deprecated__zzz(\"use foo instead\")
  fn foo() -> Nil {
    Nil
  }",
    )
    == error.UnknownAttribute("deprecated__zzz")
}

pub fn known_attributes_are_fine_test() {
  helpers.ok_module_typecheck(
    "@deprecated(\"old\")
  @target(erlang)
  @internal
  pub fn foo() -> Nil {
    Nil
  }",
  )
}

pub fn unknown_attribute_on_custom_type_test() {
  assert helpers.error_module_typecheck(
      "@foo
  pub type Bar {
    Bar
  }",
    )
    == error.UnknownAttribute("foo")
}

pub fn record_update_as_call_argument_keeps_rigid_type_vars_test() {
  assert helpers.error_module_typecheck(
      "pub opaque type Simulation(model, message) {
    Simulation(
      update: fn(model, message) -> #(model, String),
      view: fn(model) -> String,
      history: List(Int),
      model: model,
      html: String,
    )
  }
  pub type Result(a, b) {
    Ok(a)
    Error(b)
  }
  fn event(
    simulation: Simulation(model__zzz, message),
    msg: message,
  ) -> Simulation(model, message) {
    let #(model, _) = simulation.update(simulation.model, msg)
    let html = simulation.view(model)
    let history = [1, ..simulation.history]
    let updated = Ok(Simulation(..simulation, history:, model:, html:))
    case updated {
      Ok(s) -> s
      Error(e) -> e
    }
  }",
    )
    == error.InvalidReturnType(
      "event",
      "main_module.Simulation(model__zzz, message)",
      "main_module.Simulation(model, message)",
    )
}

pub fn record_update_in_use_continuation_keeps_rigid_type_vars_test() {
  assert helpers.error_module_typecheck(
      "pub opaque type Simulation(model, message) {
    Simulation(
      update: fn(model, message) -> #(model, String),
      view: fn(model) -> String,
      history: List(Int),
      model: model,
      html: String,
    )
  }
  pub type Result(a, b) {
    Ok(a)
    Error(b)
  }
  fn wrap(f: fn(Int) -> Result(a, b)) -> Result(a, b) {
    f(1)
  }
  fn event(
    simulation: Simulation(model__zzz, message),
    msg: message,
  ) -> Simulation(model, message) {
    let result = {
      use path <- wrap
      let #(model, _) = simulation.update(simulation.model, msg)
      let html = simulation.view(model)
      let history = [1, ..simulation.history]
      Ok(Simulation(..simulation, history:, model:, html:))
    }
    case result {
      Ok(simulation) -> simulation
      Error(problem) -> problem
    }
  }",
    )
    == error.InvalidReturnType(
      "event",
      "main_module.Simulation(model__zzz, message)",
      "main_module.Simulation(model, message)",
    )
}

pub fn valid_record_update_in_use_continuation_test() {
  helpers.ok_module_typecheck(
    "pub opaque type Simulation(model, message) {
    Simulation(
      update: fn(model, message) -> #(model, String),
      view: fn(model) -> String,
      history: List(Int),
      model: model,
      html: String,
    )
  }
  pub type Result(a, b) {
    Ok(a)
    Error(b)
  }
  fn wrap(f: fn(Int) -> Result(a, b)) -> Result(a, b) {
    f(1)
  }
  fn event(
    simulation: Simulation(model, message),
    msg: message,
  ) -> Simulation(model, message) {
    let result = {
      use path <- wrap
      let #(model, _) = simulation.update(simulation.model, msg)
      let html = simulation.view(model)
      let history = [1, ..simulation.history]
      Ok(Simulation(..simulation, history:, model:, html:))
    }
    case result {
      Ok(simulation) -> simulation
      Error(problem) -> problem
    }
  }",
  )
}

pub fn record_update_on_polymorphic_const_with_lambda_annotation_test() {
  assert helpers.error_module_typecheck(
      "pub type Actions(a) {
    Actions(dispatch: fn(a) -> Nil, root: fn() -> Nil)
  }
  pub type Box(a) {
    Box(
      synchronous: List(fn(Actions(a)) -> Nil),
      before_paint: List(fn(Actions(a)) -> Nil),
      after_paint: List(fn(Actions(a)) -> Nil),
    )
  }
  const empty: Box(a) = Box([], [], [])
  pub fn take(effect: fn(fn(a) -> Nil, a) -> Nil, x: a) -> Box(b) {
    Box(..empty, before_paint: [
      fn(actions: Actions(a)) {
        let dispatch = actions.dispatch
        effect(dispatch, x)
      },
    ])
  }",
    )
    == error.InvalidReturnType(
      "take",
      "main_module.Box(a)",
      "main_module.Box(b)",
    )
}

pub fn valid_record_update_on_polymorphic_const_with_lambda_annotation_test() {
  helpers.ok_module_typecheck(
    "pub type Actions(a) {
    Actions(dispatch: fn(a) -> Nil, root: fn() -> Nil)
  }
  pub type Box(a) {
    Box(
      synchronous: List(fn(Actions(a)) -> Nil),
      before_paint: List(fn(Actions(a)) -> Nil),
      after_paint: List(fn(Actions(a)) -> Nil),
    )
  }
  const empty: Box(a) = Box([], [], [])
  pub fn take(effect: fn(fn(a) -> Nil, a) -> Nil, x: a) -> Box(a) {
    Box(..empty, before_paint: [
      fn(actions: Actions(a)) {
        let dispatch = actions.dispatch
        effect(dispatch, x)
      },
    ])
  }",
  )
}

pub fn capture_with_rigid_param_test() {
  assert helpers.error_module_typecheck(
      "pub type Subject(a) { Subject }
  pub type Effect(a) { Effect }
  pub type Message(a) {
    Message
    EffectDispatchedMessage(message: a)
  }
  pub fn send_capture(self: Subject(Message(a)), message: Message(a)) -> Nil {
    Nil
  }
  pub fn perform(effect: Effect(message), dispatch: fn(message) -> Nil) -> Nil {
    case effect {
      Effect -> Nil
    }
  }
  pub fn handle_effect(
    self: Subject(Message(message__zzz)),
    effect: Effect(message),
  ) -> Nil {
    let send = send_capture(self, _)
    let dispatch = fn(message) { send(EffectDispatchedMessage(message:)) }
    perform(effect, dispatch)
  }",
    )
    == error.InvalidArguments(
      "(main_module.Effect(var_5), fn (var_5) -> Nil)",
      "(main_module.Effect(var_1), fn (var_0) -> Nil)",
    )
}

pub fn capture_with_same_rigid_param_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type Subject(a) { Subject }
  pub type Effect(a) { Effect }
  pub type Message(a) {
    Message
    EffectDispatchedMessage(message: a)
  }
  pub fn send_capture(self: Subject(Message(a)), message: Message(a)) -> Nil {
    Nil
  }
  pub fn perform(effect: Effect(message), dispatch: fn(message) -> Nil) -> Nil {
    case effect {
      Effect -> Nil
    }
  }
  pub fn handle_effect(
    self: Subject(Message(message)),
    effect: Effect(message),
  ) -> Nil {
    let send = send_capture(self, _)
    let dispatch = fn(message) { send(EffectDispatchedMessage(message:)) }
    perform(effect, dispatch)
  }",
  )
}

pub fn pipe_into_capture_keeps_rigid_type_var_test() {
  assert helpers.error_module_typecheck(
      "pub type Blob { Blob }
  pub type Cache(a) { Cache }
  pub type Handler(a) { Handler }
  pub type Result(a, b) {
    Ok(a)
    Error(b)
  }
  pub fn decode(
    cache: Cache(a),
    path: String,
    name: String,
    event: Blob,
  ) -> #(Cache(a), Result(Handler(a), Nil)) {
    #(cache, Ok(Handler))
  }
  pub fn dispatch(
    cache: Cache(a),
    decoded: #(Cache(a), Result(Handler(a), Nil)),
  ) -> #(Cache(a), Result(Handler(a), Nil)) {
    decoded
  }
  pub fn handle(
    cache: Cache(message__zzz),
    path: String,
    name: String,
    event: Blob,
  ) -> #(Cache(message), Result(Handler(message), Nil)) {
    decode(cache, path, name, event) |> dispatch(cache, _)
  }",
    )
    == error.InvalidReturnType(
      "handle",
      "(main_module.Cache(message__zzz), main_module.Result(main_module.Handler(message__zzz), Nil))",
      "(main_module.Cache(message), main_module.Result(main_module.Handler(message), Nil))",
    )
}

pub fn pipe_into_capture_with_same_rigid_type_var_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type Blob { Blob }
  pub type Cache(a) { Cache }
  pub type Handler(a) { Handler }
  pub type Result(a, b) {
    Ok(a)
    Error(b)
  }
  pub fn decode(
    cache: Cache(a),
    path: String,
    name: String,
    event: Blob,
  ) -> #(Cache(a), Result(Handler(a), Nil)) {
    #(cache, Ok(Handler))
  }
  pub fn dispatch(
    cache: Cache(a),
    decoded: #(Cache(a), Result(Handler(a), Nil)),
  ) -> #(Cache(a), Result(Handler(a), Nil)) {
    decoded
  }
  pub fn handle(
    cache: Cache(message),
    path: String,
    name: String,
    event: Blob,
  ) -> #(Cache(message), Result(Handler(message), Nil)) {
    decode(cache, path, name, event) |> dispatch(cache, _)
  }",
  )
}

pub fn recursive_call_keeps_rigid_type_var_test() {
  assert helpers.error_module_typecheck(
      "pub type Element(a) { Element(keyed_children: MutableMap(String, Element(a))) }
  pub type MutableMap(k, v) { MutableMap }
  pub fn work(
    new new: List(Element(message)),
    new_keyed new_keyed: MutableMap(String, Element(message__zzz)),
    n n: Int,
  ) -> Int {
    case n {
      0 -> 0
      _ ->
        case new {
          [] -> 0
          [next, ..rest] ->
            work(new: rest, new_keyed: next.keyed_children, n: n - 1)
        }
    }
  }",
    )
    == error.InvalidArguments(
      "(List(main_module.Element(var_0)), main_module.MutableMap(String, main_module.Element(var_1)), Int)",
      "(List(main_module.Element(var_0)), main_module.MutableMap(String, main_module.Element(var_0)))",
    )
}

pub fn recursive_call_with_same_rigid_type_var_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type Element(a) { Element(keyed_children: MutableMap(String, Element(a))) }
  pub type MutableMap(k, v) { MutableMap }
  pub fn work(
    new new: List(Element(message)),
    new_keyed new_keyed: MutableMap(String, Element(message)),
    n n: Int,
  ) -> Int {
    case n {
      0 -> 0
      _ ->
        case new {
          [] -> 0
          [next, ..rest] ->
            work(new: rest, new_keyed: next.keyed_children, n: n - 1)
        }
    }
  }",
  )
}

pub fn todo_with_message_is_fine_test() {
  // `todo("msg")` is a call to the prelude wildcard value; its argument is
  // typechecked and the whole expression unifies with anything.
  helpers.ok_module_typecheck("pub fn f() -> Int { todo(\"msg\") }")
  helpers.ok_module_typecheck("pub fn f() -> Int { todo(1.5) }")
}

pub fn panic_with_message_is_fine_test() {
  helpers.ok_module_typecheck("pub fn f() -> Int { panic(\"boom\") }")
}

pub fn todo_message_is_typechecked_test() {
  // The message is a normal expression: an undefined variable or a type error
  // inside it is reported.
  assert helpers.error_module_typecheck(
      "pub fn f() -> Int { todo(undefined_var) }",
    )
    == error.InvalidName("undefined_var")
  assert helpers.error_module_typecheck(
      "pub fn f() -> Int { todo(\"msg\" <> 1) }",
    )
    == error.InvalidBinOp("<>", "String", "Int", "two Strings")
}

pub fn todo_as_type_name_message_is_rejected_test() {
  // `todo as String` parses the type name as the message, which is a type used
  // as a value; the real compiler reports an unknown variable.
  assert helpers.error_module_typecheck("pub fn f() -> Int { todo as String }")
    == error.InvalidName("String")
  assert helpers.error_module_typecheck(
      "pub fn f() -> Int { panic as Result(Int, String) }",
    )
    == error.InvalidName("Result")
}

pub fn variable_with_uppercase_in_name_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "pub fn f() -> Int {
  let fooBar = 1
  fooBar
}",
    )
    == error.InvalidVariableName("fooBar")
}

pub fn variable_with_underscore_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn f() -> Int {
  let foo_bar = 1
  foo_bar
}",
  )
}
