import glimpse/error
import typecheck/helpers

pub fn updating_a_multi_variant_value_test() {
  assert helpers.error_module_typecheck(
      "pub type Wibble {
  Wibble(wibble: Int, wubble: Bool)
  Wobble(wobble: Int, wubble: Bool)
}
pub fn wibble(value: Wibble) { Wibble(..value, wubble: True) }",
    )
    == error.UnsafeRecordUpdate("Wibble")
}

pub fn updating_a_single_variant_value_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type Wibble { Wibble(wibble: Int, wubble: Bool) }
pub fn wibble(value: Wibble) { Wibble(..value, wubble: True) }",
  )
}

pub fn duplicate_field_in_update_test() {
  assert helpers.error_module_typecheck(
      "pub type Wibble { Wibble(thing: Int, other: Int) }
pub fn main() {
  let wibble = Wibble(1, 2)
  let wobble = Wibble(..wibble, thing: 1, thing: 2)
  wobble
}",
    )
    == error.DuplicateArgument("thing")
}

pub fn cross_variant_update_test() {
  assert helpers.error_module_typecheck(
      "pub type Wibble {
  A(a: Int, b: Int)
  B(a: Int, b: Int)
}
pub fn b_to_a(value: Wibble) {
  case value {
    A(..) -> value
    B(..) as b -> A(..b, a: 3)
  }
}",
    )
    == error.UnsafeRecordUpdate("A")
}

pub fn updating_a_type_parameter_across_variants_test() {
  assert helpers.error_module_typecheck(
      "pub type Wibble(a) { Wibble(a: a, b: a) }
pub fn b_to_a(value: Wibble(a)) -> Wibble(Int) {
  Wibble(..value, a: 5)
}",
    )
    == error.UnsafeRecordUpdate("Wibble")
}

pub fn shorthand_field_requires_variable_in_scope_test() {
  // `index:` is shorthand for `index: index`; the variable must exist.
  assert helpers.error_module_typecheck(
      "pub type Patch {
    Patch(index: Int, path: List(Int))
  }
  pub fn add_parent(child: Patch, index__zzz: Int) -> Patch {
    Patch(..child, path: [child.index], index:)
  }",
    )
    == error.InvalidName("index")
}

pub fn shorthand_field_with_variable_in_scope_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type Patch {
    Patch(index: Int, path: List(Int))
  }
  pub fn add_parent(child: Patch, index: Int) -> Patch {
    Patch(..child, path: [child.index], index:)
  }",
  )
}

pub fn unknown_field_in_update_test() {
  assert helpers.error_module_typecheck(
    "pub type Wibble {
    Wibble(a: Int, b: String)
  }
  pub fn f(base: Wibble) -> Wibble {
    Wibble(..base, zzz: 1)
  }",
    )
    == error.InvalidFieldAccess("main_module.Wibble", "zzz")
}

pub fn wrong_field_type_in_update_test() {
  assert helpers.error_module_typecheck(
    "pub type Wibble {
    Wibble(a: Int, b: String)
  }
  pub fn f(base: Wibble) -> Wibble {
    Wibble(..base, a: \"not an int\")
  }",
    )
    == error.InvalidType("String", "Int", "in record update of field a")
}
