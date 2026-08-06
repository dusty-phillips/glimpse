import glimpse/error
import typecheck/helpers

pub fn unnecessary_spread_operator_test() {
  assert helpers.error_module_typecheck(
      "pub type Triple {
    Triple(a: Int, b: Int, c: Int)
  }
  pub fn main() {
    let triple = Triple(1, 2, 3)
    let Triple(a, b, c, ..) = triple
    a
  }",
    )
    == error.UnnecessarySpread
}

pub fn spread_when_fields_omitted_test() {
  helpers.ok_module_typecheck(
    "pub type Triple {
    Triple(a: Int, b: Int, c: Int)
  }
  pub fn main() {
    let triple = Triple(1, 2, 3)
    let Triple(a, ..) = triple
    a
  }",
  )
}
