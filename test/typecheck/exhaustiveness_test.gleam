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
