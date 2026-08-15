import glimpse/error
import typecheck/helpers

pub fn inexhaustive_bool_test() {
  assert helpers.error_module_typecheck(
      "pub fn main(x: Bool) { case x { True -> 1 } }",
    )
    == error.InexhaustivePattern("False")
}

pub fn exhaustive_bool_test() {
  helpers.ok_module_typecheck(
    "pub fn main(x: Bool) { case x { True -> 1 False -> 2 } }",
  )
}

pub fn inexhaustive_custom_type_test() {
  assert helpers.error_module_typecheck(
      "pub type Type { One Two }
pub fn main(x: Type) { case x { One -> 1 } }",
    )
    == error.InexhaustivePattern("Two")
}

pub fn exhaustive_custom_type_test() {
  helpers.ok_module_typecheck(
    "pub type Type { One Two }
pub fn main(x: Type) { case x { One -> 1 Two -> 2 } }",
  )
}

pub fn guarded_clause_does_not_cover_test() {
  assert helpers.error_module_typecheck(
      "pub fn main(b: Bool) -> Int {
        case b { True if True -> 1 False -> 2 }
      }",
    )
    == error.InexhaustivePattern("True")
}

pub fn guarded_clause_with_catch_all_is_exhaustive_test() {
  helpers.ok_module_typecheck(
    "pub fn main(x: Int) -> Int {
      case x { _ if x == 1 -> 1 _ -> 0 }
    }",
  )
}

pub fn refutable_let_pattern_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "pub fn main(b: Bool) { let True = b b }",
    )
    == error.InexhaustivePattern("False")
}

pub fn irrefutable_let_patterns_are_accepted_test() {
  helpers.ok_module_typecheck(
    "pub fn main(b: Bool) {
      let flag = b
      let x = b
      x
    }",
  )
}

pub fn recursive_list_patterns_are_exhaustive_test() {
  helpers.ok_module_typecheck(
    "pub fn main(xs: List(Int)) -> Int {
      case xs {
        [] -> 0
        [x] -> 1
        [x, y, ..rest] -> 2
      }
    }",
  )
}

pub fn list_case_missing_fixed_length_and_tail_test() {
  assert helpers.error_module_typecheck(
      "pub fn main(xs: List(Int)) -> Int {
        case xs { [x, y] -> 1 }
      }",
    )
    == error.InexhaustivePattern("[_, ..]\n[]\n[]")
}

pub fn list_case_missing_two_element_pattern_test() {
  assert helpers.error_module_typecheck(
      "pub fn main(xs: List(Int)) -> Int {
        case xs { [] -> 0 [x] -> 1 }
      }",
    )
    == error.InexhaustivePattern("[_, ..]")
}

pub fn recursive_custom_type_case_is_exhaustive_test() {
  helpers.ok_module_typecheck(
    "pub type Tree { Leaf(Int) Node(Tree, Tree) }
pub fn main(t: Tree) -> Int {
  case t {
    Leaf(_) -> 0
    Node(left, right) -> 1 + main(left) + main(right)
  }
}",
  )
}

pub fn generic_type_payload_patterns_are_exhaustive_test() {
  helpers.ok_module_typecheck(
    "pub type CaCert {
  CaCertFile(path: String)
  CaCertData(certs: List(BitArray))
}
pub type Wrapper(a) {
  Wrap(a)
}
pub fn main(wrapper: Wrapper(CaCert)) -> Int {
  case wrapper {
    Wrap(CaCertFile(path)) -> 1
    Wrap(CaCertData(certs)) -> 2
  }
}",
  )
}

pub fn generic_type_payload_missing_constructor_is_inexhaustive_test() {
  assert helpers.error_module_typecheck(
      "pub type CaCert {
  CaCertFile(path: String)
  CaCertData(certs: List(BitArray))
}
pub type Wrapper(a) {
  Wrap(a)
}
pub fn main(wrapper: Wrapper(CaCert)) -> Int {
  case wrapper {
    Wrap(CaCertFile(path)) -> 1
  }
}",
    )
    == error.InexhaustivePattern("Wrap(CaCertData(_))")
}

pub fn missing_constructor_with_argument_shows_underscore_test() {
  assert helpers.error_module_typecheck(
      "pub fn main(x: Result(Int, Nil)) {
        case x { Ok(1) -> 1 }
      }",
    )
    == error.InexhaustivePattern("Ok(_)\nError(_)")
}

pub fn partially_covered_constructor_shows_missing_argument_test() {
  assert helpers.error_module_typecheck(
      "pub fn main(x: Result(Bool, Nil)) {
        case x { Ok(True) -> 1 }
      }",
    )
    == error.InexhaustivePattern("Ok(False)\nError(_)")
}

pub fn nested_missing_constructor_is_wrapped_test() {
  assert helpers.error_module_typecheck(
      "pub type Wrapper(a) { Wrap(a) }
      pub fn main(x: Wrapper(Result(Int, Nil))) {
        case x { Wrap(Ok(1)) -> 1 }
      }",
    )
    == error.InexhaustivePattern("Wrap(Ok(_))\nWrap(Error(_))")
}

pub fn list_cons_missing_pattern_matches_official_test() {
  assert helpers.error_module_typecheck(
      "pub fn main(x: List(Int)) {
        case x { [_] -> 1 }
      }",
    )
    == error.InexhaustivePattern("[_, ..]\n[]")
}

pub fn spread_labelled_patterns_are_exhaustive_test() {
  helpers.ok_module_typecheck(
    "pub type Maybe {
  Just(Int)
  Nothing
}
pub type Three {
  Three(first: Int, second: List(Int), third: Maybe)
}
pub fn main(x: Three) -> Int {
  case x {
    Three(third: Just(n), ..) -> n
    Three(third: Nothing, ..) -> 0
  }
}",
  )
}

pub fn spread_labelled_pattern_missing_constructor_test() {
  assert helpers.error_module_typecheck(
      "pub type Maybe {
  Just(Int)
  Nothing
}
pub type Three {
  Three(first: Int, second: List(Int), third: Maybe)
}
pub fn main(x: Three) -> Int {
  case x {
    Three(third: Just(n), ..) -> n
  }
}",
    )
    == error.InexhaustivePattern("Nothing")
}

pub fn exhaustive_on_inferred_return_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn g() {
  True
}

pub fn f() -> Int {
  case g() {
    True -> 1
    False -> 0
  }
}",
  )
}

pub fn inexhaustive_on_inferred_return_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "pub fn g() {
  True
}

pub fn f() -> Int {
  case g() {
    True -> 1
  }
}",
    )
    == error.InexhaustivePattern("False")
}

pub fn error_nil_pattern_covers_error_variant_test() {
  helpers.ok_module_typecheck(
    "pub fn run(x: Result(Int, Nil)) -> Int {
  case x {
    Error(Nil) -> 0
    Ok(v) -> v
  }
}",
  )
}

pub fn error_nil_pattern_with_inferred_subject_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn run() -> Int {
  let x = Ok(1)
  case x {
    Error(Nil) -> 0
    Ok(v) -> v
  }
}",
  )
}

pub fn empty_lambda_with_expected_type_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub fn apply(x: Int, f: fn(Int) -> String) -> String {
  f(x)
}

pub fn main() -> String {
  apply(1, fn(y) {
  })
}",
  )
}

pub fn private_type_in_public_custom_type_field_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "type Secret {
    Secret(value: Int)
  }

  pub type Holder {
    Holder(secret: Secret)
  }",
    )
    == error.PrivateTypeLeak("Secret")
}

pub fn private_type_in_public_opaque_type_field_is_fine_test() {
  helpers.ok_module_typecheck(
    "type Secret {
  Secret(value: Int)
}

pub opaque type Holder {
  Holder(secret: Secret)
}",
  )
}

pub fn deleted_clause_on_inferred_call_result_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "pub type Event

pub fn wrap(raw: Int, f: fn(Int) -> Result(Event, Nil)) -> Result(Event, Nil) {
  case f(raw) {
    Error(Nil) -> Error(Nil)
  }
}",
    )
    == error.InexhaustivePattern("Ok(_)")
}

pub fn complete_case_on_inferred_call_result_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type Event

pub fn wrap(raw: Int, f: fn(Int) -> Result(Event, Nil)) -> Result(Event, Nil) {
  case f(raw) {
    Ok(event) -> Ok(event)
    Error(Nil) -> Error(Nil)
  }
}",
  )
}

/// Disabled: the published glance rejects the body-less `case x` syntax at parse time. Kept as documentation.
pub fn bodyless_case_in_analysed_code_is_rejected() {
  assert helpers.error_module_typecheck(
      "pub fn f(x: Int) -> Int {
  case x
  1
}",
    )
    == error.InexhaustivePattern("_")
}

/// Disabled: the published glance rejects the body-less `case x` syntax at parse time. Kept as documentation.
pub fn bodyless_case_in_filtered_function_is_fine() {
  helpers.ok_module_typecheck(
    "@target(javascript)
pub fn f(x: Int) -> Int {
  case x
  1
}",
  )
}
