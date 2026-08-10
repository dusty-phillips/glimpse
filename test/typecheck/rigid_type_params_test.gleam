import glimpse/error
import typecheck/helpers

/// A function's own declared type parameters are *rigid* during body checking:
/// the real compiler rejects binding one to a concrete type or to a different
/// type parameter. These tests pin the rigid-vs-flexible distinction that the
/// mutation harness surfaced: glimpse used to accept `x && y`, `Error(x)`, and
/// `case xs, xs` on generic parameters, all of which real Gleam rejects.
pub fn bool_operator_on_generic_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "fn f(x: a, y: a) -> Bool {
      x && y
    }",
    )
    == error.InvalidBinOp("&&", "a", "a", "two Bools")
}

pub fn or_operator_on_generic_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "fn f(x: a, y: a) -> Bool {
      x || y
    }",
    )
    == error.InvalidBinOp("||", "a", "a", "two Bools")
}

pub fn error_constructor_with_generic_value_is_rejected_test() {
  // `Error` requires its second type parameter, so `Error(x)` where `x: a`
  // cannot be the error side of `Result(a, Nil)`.
  let assert error.InvalidReturnType("f", _, _) =
    helpers.error_module_typecheck(
      "fn f(x: a) -> Result(a, Nil) {
      Error(x)
    }",
    )
}

pub fn ok_constructor_with_wrong_generic_side_is_rejected_test() {
  let assert error.InvalidReturnType("f", _, _) =
    helpers.error_module_typecheck(
      "fn f(x: a) -> Result(Nil, a) {
      Ok(x)
    }",
    )
}

pub fn case_on_two_different_generic_lists_is_rejected_test() {
  // Matching two differently-typed lists and comparing their elements forces
  // `a = b` through `==`, which is not allowed for distinct type parameters.
  let _ =
    helpers.error_module_typecheck(
      "pub fn f(list1: List(a), list2: List(b)) -> Bool {
      case list1, list2 {
        [x, ..], [y, ..] -> x == y
        _, _ -> False
      }
    }",
    )
}

pub fn case_subjects_forcing_same_param_is_rejected_test() {
  // Using `list1` for both subjects binds `x` and `y` to the same `a`, then
  // calling `combine` (which needs `fn(a, b)`) with both must fail.
  let _ =
    helpers.error_module_typecheck(
      "pub fn f(
      list1: List(a),
      list2: List(b),
      combine: fn(a, b) -> Bool,
    ) -> Bool {
      case list1, list1 {
        [x, ..], [y, ..] -> combine(x, y)
        _, _ -> False
      }
    }",
    )
}

pub fn passing_same_list_twice_to_multi_generic_is_rejected_test() {
  // `map2_loop(list2, list2, ...)` forces the first two parameters of the
  // generic callee to be equal, but they are distinct rigid type parameters.
  let _ =
    helpers.error_module_typecheck(
      "fn map2_loop(
      list1: List(a),
      list2: List(b),
      fun: fn(a, b) -> c,
      acc: List(c),
    ) -> List(c) {
      map2_loop(list2, list2, fun, [])
    }",
    )
}

pub fn generic_return_must_match_annotation_test() {
  let _ =
    helpers.error_module_typecheck(
      "fn f(x: a) -> a {
      1
    }",
    )
}

pub fn generic_parameter_not_usable_as_concrete_test() {
  // A rigid `a` may not flow into a position expecting `Int`.
  let _ =
    helpers.error_module_typecheck(
      "fn f(x: a) -> Int {
      x
    }",
    )
}

pub fn higher_order_rigid_parameter_rejects_concrete_test() {
  // `fun` is `fn(a) -> a` with rigid `a`, so passing `1` is an error even
  // though instantiation would otherwise freshen `a` to accept it.
  let _ =
    helpers.error_module_typecheck(
      "fn f(fun: fn(a) -> a, x: a) -> a {
      fun(1)
    }",
    )
}

// ---------------------------------------------------------------------------
// Valid uses of generic parameters must keep working.
// ---------------------------------------------------------------------------

pub fn identity_function_is_fine_test() {
  helpers.ok_module_typecheck("fn identity(x: a) -> a { x }")
}

pub fn generic_comparison_within_same_type_is_fine_test() {
  // `==` on two values of the same rigid `a` is allowed (both sides agree).
  helpers.ok_module_typecheck(
    "fn f(x: a, y: a) -> Bool {
      x == y
    }",
  )
}

pub fn generic_parameter_used_in_container_is_fine_test() {
  helpers.ok_module_typecheck("fn f(x: a) -> List(a) { [x, x] }")
}

pub fn higher_order_parameter_applied_to_own_generic_is_fine_test() {
  helpers.ok_module_typecheck(
    "fn apply(fun: fn(a) -> a, x: a) -> a {
      fun(x)
    }",
  )
}

pub fn generic_pattern_binding_is_fine_test() {
  helpers.ok_module_typecheck(
    "fn f(xs: List(a)) -> a {
      case xs {
        [first, ..] -> first
        [] -> panic
      }
    }",
  )
}

pub fn map2_style_generic_function_is_fine_test() {
  helpers.ok_module_typecheck(
    "fn map2_loop(
      list1: List(a),
      list2: List(b),
      fun: fn(a, b) -> c,
      acc: List(c),
    ) -> List(c) {
      case list1, list2 {
        [], _ | _, [] -> acc
        [a, ..as_], [b, ..bs] -> map2_loop(as_, bs, fun, [fun(a, b), ..acc])
      }
    }",
  )
}

pub fn generic_function_called_polymorphically_is_fine_test() {
  // The declared `a` stays rigid inside `id`, but each call site instantiation
  // freshens it so `id` can be used with both `Int` and `String`.
  helpers.ok_module_typecheck(
    "fn id(x: a) -> a { x }
    pub fn main() {
      id(1)
      id(\"hello\")
    }",
  )
}

pub fn generic_call_result_used_as_error_value_is_rejected_test() {
  // `local_fold(rest, first, fun)` has type `a`, so `Error(...)` around it
  // cannot be the `Nil` error side of `Result(a, Nil)`. The call's return must
  // keep its rigid link to `a` even after being passed as an argument.
  let _ =
    helpers.error_module_typecheck(
      "fn local_fold(xs: List(a), init: a, fun: fn(a, a) -> a) -> a { init }

    pub fn reduce(over list: List(a), with fun: fn(a, a) -> a) -> Result(a, Nil) {
      case list {
        [] -> Error(Nil)
        [first, ..rest] -> Error(local_fold(rest, first, fun))
      }
    }",
    )
}

pub fn const_value_must_match_annotation_test() {
  // The annotation is checked against the value's *resolved* type, so a
  // constructor argument's inferred type variable is resolved before the
  // comparison (and the store threaded through the value typecheck).
  let assert error.InvalidAnnotation("main_module.Wrap(Bool)", _, "ok") =
    helpers.error_module_typecheck(
      "pub type Wrap(a) {
      Wrap(fn() -> a)
    }

    fn bool_val() -> Bool { True }

    pub const ok: Wrap(Int) = Wrap(bool_val)",
    )
}

pub fn lambda_annotated_param_rigidity_is_preserved_test() {
  // A lambda's annotated type variables are rigid within its body, so
  // `a_pair.1` (a tuple of `Float` and rigid `a`) cannot feed `float.compare`.
  let _ =
    helpers.error_module_typecheck(
      "fn compare(a: Float, b: Float) -> Int { 0 }

    pub fn f(a_pair: #(Float, a), b_pair: #(Float, a)) -> Int {
      compare(a_pair.1, b_pair.1)
    }",
    )
}

pub fn lambda_annotated_param_generic_use_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn f(a_pair: #(Float, a), b_pair: #(Float, a)) -> a {
      a_pair.1
    }",
  )
}

pub fn pattern_bound_value_in_error_slot_is_rejected_test() {
  // `value` is bound from the `Some(value)` pattern, so its type is the rigid
  // `a`. Placing it in `Error(...)` forces `a = e`, which is not allowed for
  // distinct type parameters. A pattern-bound value must keep the rigid
  // identity of the parameter it came from instead of being re-instantiated.
  let _ =
    helpers.error_module_typecheck(
      "pub type Choice(a) {
      Picked(a)
      Empty
    }

    pub fn to_result(choice: Choice(a), e: e) -> Result(a, e) {
      case choice {
        Picked(value) -> Error(value)
        Empty -> Error(e)
      }
    }",
    )
}

pub fn tuple_index_on_rigid_in_unannotated_lambda_is_rejected_test() {
  // The lambda parameters are bound to `#(String, t)` from the expected
  // callable type, so `a.1` is the rigid `t`. Comparing it as a String is not
  // allowed even though the lambda parameters carry no annotations.
  let _ =
    helpers.error_module_typecheck(
      "pub fn sort_keys(pairs: List(#(String, t))) -> List(String) {
      list.sort(pairs, fn(a, b) { string.compare(a.1, b.1) })
      |> list.map(fn(pair) { pair.0 })
    }",
    )
}

pub fn record_update_shorthand_with_generic_value_is_fine_test() {
  // `contents` is generalised to `List(a)` by its binding; the record update
  // must instantiate it against the concrete `List(message)` field type rather
  // than comparing generic names.
  helpers.ok_module_typecheck(
    "pub type Box(message) {
      Box(contents: List(message))
    }

    fn empty() -> List(a) { [] }

    pub fn replace(box: Box(message)) -> Box(message) {
      let contents = empty()
      Box(..box, contents:)
    }",
  )
}

pub fn field_access_value_in_error_slot_is_rejected_test() {
  // `maybe_invalid_data` is bound by destructuring `decoder.function(input)`,
  // whose type is expressed in terms of the rigid `t` of `decoder`. Placing it
  // in `Error(...)` (the `List(DecodeError)` slot) is rejected.
  let _ =
    helpers.error_module_typecheck(
      "pub type DecodeError {
      DecodeError
    }

    pub type Decoder(t) {
      Decoder(function: fn(Int) -> #(t, List(DecodeError)))
    }

    pub fn run(input: Int, decoder: Decoder(t)) -> Result(t, List(DecodeError)) {
      let #(maybe_invalid_data, errors) = decoder.function(input)
      case errors {
        [] -> Error(maybe_invalid_data)
        [_, ..] -> Error(errors)
      }
    }",
    )
}

pub fn generic_helper_return_in_error_slot_is_rejected_test() {
  // `max_loop(rest, compare, first)` returns the callee's generic `a`, which
  // the arguments pin to the caller's rigid `a`; `Error(...)` therefore puts
  // the rigid `a` in the `Nil` slot.
  let _ =
    helpers.error_module_typecheck(
      "import gleam/order

    fn max_loop(
      list: List(a),
      compare: fn(a, a) -> order.Order,
      max: a,
    ) -> a {
      case list {
        [] -> max
        [first, ..rest] -> max_loop(rest, compare, first)
      }
    }

    pub fn max(
      list: List(a),
      compare: fn(a, a) -> order.Order,
    ) -> Result(a, Nil) {
      case list {
        [] -> Error(Nil)
        [first, ..rest] -> Error(max_loop(rest, compare, first))
      }
    }",
    )
}

pub fn recursive_unannotated_helper_return_is_rejected_test() {
  // `loop`'s parameters are unannotated, so its signature starts as the
  // `todo` wildcard; the finite recursion must still finalise it to
  // `fn(List(a), a) -> a` so its return carries the caller's rigid `a`.
  let _ =
    helpers.error_module_typecheck(
      "fn loop(list, max) {
      case list {
        [] -> max
        [first, ..rest] -> loop(rest, first)
      }
    }

    pub fn f(list: List(a)) -> Result(a, Nil) {
      case list {
        [] -> Error(Nil)
        [first, ..rest] -> Error(loop(rest, first))
      }
    }",
    )
}

pub fn return_annotation_distinct_generics_rejected_test() {
  // The return annotation's type variables are rigid like the parameters', so
  // a body returning `fn(a) -> a` cannot satisfy a `fn(b) -> b` annotation.
  let assert error.InvalidReturnType("take", _, _) =
    helpers.error_module_typecheck(
      "fn take(f: fn(a) -> a) -> fn(b) -> b {
      f
    }",
    )
}

pub fn annotated_lambda_stays_polymorphic_test() {
  // A lambda's annotated type variables are rigid *inside* its body but the
  // lambda itself is polymorphic, so it can be used at different types.
  helpers.ok_module_typecheck(
    "pub fn f() -> String {
      let g = fn(x: a, y: b) -> b { y }
      let _ = g(1, 2)
      g(\"a\", \"b\")
    }",
  )
}

pub fn inferred_let_binding_is_monomorphic_test() {
  // `let xs = []` infers `List(a)` with a *monomorphic* `a`: real Gleam does
  // not generalise inference variables at a binding, so using `xs` at two
  // different element types is rejected.
  let _ =
    helpers.error_module_typecheck(
      "import gleam/list

    pub fn f() -> String {
      let xs = []
      let _ = list.map(xs, fn(x) { x + 1 })
      list.first(xs) |> result.unwrap(\"a\")
    }",
    )
}

pub fn unannotated_lambda_binding_is_monomorphic_test() {
  // The parameters of an unannotated lambda are inference variables, bound
  // monomorphically at the `let`; using it at two different types is rejected.
  let _ =
    helpers.error_module_typecheck(
      "pub fn f() -> String {
      let g = fn(x, y) { y }
      let _ = g(1, 2)
      g(\"a\", \"b\")
    }",
    )
}

pub fn lambda_params_pinned_to_rigid_stay_rigid_test() {
  // An unannotated wrapper lambda whose parameters the body pins to the
  // function's rigid `k`/`v` must not be re-instantiated when passed to a
  // callee whose `Dict(v, k)` conflicts with the rigid `Dict(k, v)`.
  let _ =
    helpers.error_module_typecheck(
      "pub type Dict(k, v) {
      Dict
    }

    fn do_fold(
      fun: fn(k, v, acc) -> acc,
      initial: acc,
      dict: Dict(v, k),
    ) -> acc {
      initial
    }

    pub fn fold(
      dict: Dict(k, v),
      initial: acc,
      outer: fn(acc, k, v) -> acc,
    ) -> acc {
      let wrapper = fn(key, value, acc) { outer(acc, key, value) }
      do_fold(wrapper, initial, dict)
    }",
    )
}

pub fn return_annotation_swapped_generics_rejected_test() {
  // The return annotation `Decoder(Dict(value, key))` swaps the distinct rigid
  // parameters; the body pins `Dict(key, value)` through its inner lambda, so
  // the annotation cannot be satisfied.
  let _ =
    helpers.error_module_typecheck(
      "import gleam/dict.{type Dict}

    pub type Decoder(t) {
      Decoder(function: fn(Int) -> t)
    }

    fn decode_error(name: String, data: Int) -> List(Int) {
      []
    }

    fn decode_dict(data: Int) -> Result(Dict(Int, Int), Nil) {
      Ok(dict.new())
    }

    fn fold_dict(
      acc: #(Dict(k, v), List(Int)),
      key: Int,
      value: Int,
      key_decoder: fn(Int) -> #(k, List(Int)),
      value_decoder: fn(Int) -> #(v, List(Int)),
    ) -> #(Dict(k, v), List(Int)) {
      acc
    }

    pub fn dict(
      key: Decoder(key),
      value: Decoder(value),
    ) -> Decoder(Dict(value, key)) {
      Decoder(fn(data) {
        case decode_dict(data) {
          Error(_) -> #(dict.new(), decode_error(\"Dict\", data))
          Ok(dict) ->
            dict.fold(dict, #(dict.new(), []), fn(a, k, v) {
              fold_dict(a, k, v, key.function, value.function)
            })
        }
      })
    }",
    )
}

pub fn capture_branches_with_different_generic_names_unify_test() {
  // Each `case` branch is a capture of a polymorphic function. Generalising
  // the two captures can name their type variables differently (one is pinned
  // to a rigid parameter by its argument, the other is not); unifying them
  // must instantiate both sides rather than compare names.
  let _ =
    helpers.ok_module_typecheck(
      "pub type Message(child_argument, child_data) {
      Message(child_argument, child_data)
    }

    pub type Name(a) { Name(a) }

    pub type Supervisor(child_argument, child_data) {
      NamedSupervisor(name: Name(Message(child_argument, child_data)))
      PidSupervisor(pid: Int)
    }

    fn start_name(
      name: Name(Message(child_argument, child_data)),
      argument: List(child_argument),
    ) -> List(child_data) {
      []
    }

    fn start_pid(pid: Int, argument: List(child_argument)) -> List(child_data) {
      []
    }

    pub fn start(
      supervisor: Supervisor(child_argument, child_data),
      argument: List(child_argument),
    ) -> List(child_data) {
      let start = case supervisor {
        NamedSupervisor(name:) -> start_name(name, _)
        PidSupervisor(pid:) -> start_pid(pid, _)
      }
      start(argument)
    }",
    )
}

pub fn variant_refinement_preserves_rigidity_test() {
  // Refining `first` to the `Ok` variant in the case must not collapse the
  // rigid `a`/`e` to instantiable named generics, or `or` accepts a
  // `Result(e, a)` first parameter alongside `Result(a, e)`.
  let _ =
    helpers.error_module_typecheck(
      "pub fn or(first: Result(e, a), second: Result(a, e)) -> Result(a, e) {
      case first {
        Ok(_) -> first
        Error(_) -> second
      }
    }",
    )
}

pub fn lambda_param_shadowing_recursive_function_name_test() {
  // A lambda parameter that shadows the enclosing function's name is a local
  // value, not a self-reference: `run()` inside `fn(run) { run() }` calls the
  // parameter. It must be checked as an ordinary higher-order call, not the
  // function's own monomorphic-recursion signature.
  helpers.ok_module_typecheck(
    "pub fn run(builder: Int) -> Int {
      apply(fn(run) { run() }, fn() { builder })
    }

    fn apply(x: fn(fn() -> Int) -> Int, value: fn() -> Int) -> Int {
      x(value)
    }",
  )
}
