import glance
import gleam/dict
import gleam/list
import glimpse
import glimpse/error
import glimpse/internal/target
import glimpse/internal/typecheck/types
import glimpse/typecheck
import typecheck/helpers

fn typecheck_with_deps(
  definition: String,
  deps: dict.Dict(String, #(String, types.Environment)),
) -> Result(#(glimpse.Module, types.Environment), error.TypeCheckError) {
  let assert Ok(module) = glance.module(definition)
  let module_envs =
    dict.fold(deps, dict.new(), fn(acc, name, pair) {
      let #(_source, env) = pair
      dict.insert(acc, name, env)
    })
  typecheck.module(
    glimpse.Module("main_module", module, []),
    module_envs,
    target.Erlang,
  )
}

fn dep_env(
  name: String,
  source: String,
) -> #(String, #(String, types.Environment)) {
  let assert Ok(module) = glance.module(source)
  let assert Ok(result) =
    typecheck.module(
      glimpse.Module(name, module, []),
      dict.new(),
      target.Erlang,
    )
  let #(_module, env) = result
  #(name, #(source, env))
}

pub fn recursive_type_through_pattern_binding_test() {
  assert helpers.error_module_typecheck(
      "fn f(xs) {
        case xs {
          [] -> []
          [h, ..t] -> [f(t)]
        }
      }
    pub fn main() { f([1, 2]) }",
    )
    == error.RecursiveType
}

pub fn recursive_type_through_let_binding_test() {
  assert helpers.error_module_typecheck(
      "fn f(xs) {
        case xs {
          [] -> []
          [h, ..t] -> [f(t)]
        }
      }
    pub fn main() {
      let xs = [1, 2]
      f(xs)
    }",
    )
    == error.RecursiveType
}

pub fn direct_infinite_recursion_is_well_typed_test() {
  helpers.ok_module_typecheck(
    "fn f(x) { f(x) }
    pub fn main() { f(1) }",
  )
}

pub fn list_sum_recursion_is_well_typed_test() {
  helpers.ok_module_typecheck(
    "fn sum(xs) {
      case xs {
        [] -> 0
        [h, ..t] -> h + sum(t)
      }
    }
    pub fn main() { sum([1, 2]) }",
  )
}

pub fn list_map_recursion_is_well_typed_test() {
  helpers.ok_module_typecheck(
    "fn map(xs) {
      case xs {
        [] -> []
        [h, ..t] -> [h, ..map(t)]
      }
    }
    pub fn main() { map([1, 2]) }",
  )
}

pub fn duplicate_import_alias_is_rejected_test() {
  let dep = dep_env("wibble", "pub fn wobble() -> Int { 1 }")
  assert typecheck_with_deps(
      "import wibble as x
      import wibble as x
      pub fn main() { x.wobble() }",
      dict.from_list([dep]),
    )
    == Error(error.DuplicateImport("x"))
}

pub fn ambiguous_import_is_rejected_test() {
  let sub = dep_env("wibble/sub", "pub fn wobble() -> Int { 1 }")
  let sub2 = dep_env("wibble2/sub", "pub fn wobble() -> Int { 2 }")
  assert typecheck_with_deps(
      "import wibble/sub
      import wibble2/sub
      pub fn main() { sub.wobble() }",
      dict.from_list([sub, sub2]),
    )
    == Error(error.DuplicateImport("sub"))
}

pub fn type_imported_as_value_is_rejected_test() {
  let dep = dep_env("wibble", "pub type X = Int")
  assert typecheck_with_deps(
      "import wibble.{X}
      pub fn main() { X }",
      dict.from_list([dep]),
    )
    == Error(error.InvalidName("X"))
}

pub fn constructor_imported_as_value_is_fine_test() {
  let dep = dep_env("wibble", "pub type Wibble { Wibble }")
  assert case
    typecheck_with_deps(
      "import wibble.{Wibble}
      pub fn main() { Wibble }",
      dict.from_list([dep]),
    )
  {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn private_dep_value_is_not_importable_test() {
  let dep = dep_env("secret", "fn hidden() -> Int { 1 }")
  assert typecheck_with_deps(
      "import secret.{hidden}
      pub fn main() { hidden() }",
      dict.from_list([dep]),
    )
    == Error(error.InvalidName("hidden"))
}

pub fn self_recursion_through_container_is_well_typed_test() {
  helpers.ok_module_typecheck(
    "fn f(xs) { f([xs]) }
    pub fn main() { f(1) }",
  )
}
