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
