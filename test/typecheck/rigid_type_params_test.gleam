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
