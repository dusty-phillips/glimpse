import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import typecheck/helpers

pub fn typecheck_single_module_package_test() {
  let package =
    helpers.ok_package_check("main_module", fn(_) {
      Ok("pub fn main() -> Nil {}")
    })

  let assert Ok(module) = dict.get(package.modules, "main_module")

  assert list.length(module.module.functions) == 1
  let assert Ok(function) = list.first(module.module.functions)
  assert function
    == glance.Definition(
      [],
      glance.Function(
        glance.Span(0, 23),
        "main",
        glance.Public,
        [],
        option.Some(
          glance.NamedType(glance.Span(17, 20), "Nil", option.None, []),
        ),
        [],
      ),
    )
}

pub fn typecheck_dependent_module_package_test() {
  helpers.ok_package_check("main_module", fn(pkg) {
    case pkg {
      "main_module" ->
        Ok(
          "import other/package

        pub fn main() -> Nil {}",
        )
      "other/package" -> Ok("pub fn other() -> Nil {}")
      _ -> panic as "only two modules in this test"
    }
  })
}

pub fn typecheck_call_to_dependent_module_package_test() {
  helpers.ok_package_check("main_module", fn(pkg) {
    case pkg {
      "main_module" ->
        Ok(
          "import other/package

        pub fn main() -> Nil {
          package.other()
        }",
        )
      "other/package" -> Ok("pub fn other() -> Nil {}")
      _ -> panic as "only two modules in this test"
    }
  })
}

/// A local variable that shadows a module alias must still let record access
/// fall back to module access when the value has no such field. In
/// `dict.insert(...)` the parameter `dict` shadows the imported `gleam/dict`
/// module, but `Box` has no `insert` field so it must resolve to
/// `other/package.insert`, not be treated as a field.
pub fn module_shadowing_value_falls_back_to_module_test() {
  helpers.ok_package_check("main_module", fn(pkg) {
    case pkg {
      "main_module" ->
        Ok(
          "import other/package as dict

        pub fn main(dict: dict.Box, value: Int) -> Nil {
          let _pair = dict.insert(dict, value)
          Nil
        }",
        )
      "other/package" ->
        Ok(
          "pub type Box {
            Box(contents: Int)
          }
          pub fn insert(into box: Box, insert value: Int) -> Box {
            Box(value)
          }",
        )
      _ -> panic as "only two modules in this test"
    }
  })
}

/// An inferred type that mentions a custom type from a module the current
/// module does not import cannot be written back as an annotation (it has no
/// way to name the module). This must leave the parameter unannotated rather
/// than panic: `Memos` is an alias to `mutable_map.MutableMap`, and a caller
/// that only imports the alias' module must still infer through it.
pub fn inferred_type_with_unimportable_module_is_left_unannotated_test() {
  let package =
    helpers.ok_package_check("main_module", fn(pkg) {
      case pkg {
        "main_module" ->
          Ok(
            "import mid/package

          pub fn pass(inner) {
            package.takes(inner)
          }",
          )
        "mid/package" ->
          Ok(
            "import base/package

          pub fn takes(inner: package.Alias(Int)) -> Int {
            1
          }",
          )
        "base/package" ->
          Ok(
            "pub type Inner(x) {
            Inner(value: x)
          }
          pub type Alias(x) = Inner(x)",
          )
        _ -> panic as "only three modules in this test"
      }
    })

  let assert Ok(module) = dict.get(package.modules, "main_module")
  let assert Ok(function) = list.first(module.module.functions)
  let assert option.None =
    list.first(function.definition.parameters)
    |> result.map(fn(param) { param.type_ })
    |> result.unwrap(option.None)
}
