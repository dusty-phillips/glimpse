import glance
import gleam/dict
import glimpse

fn empty_module(name: String) -> glimpse.Module {
  let assert Ok(module) = glance.module("")
  glimpse.Module(name, module, [])
}

pub fn no_dependencies_test() {
  let assert Ok(glance_module) = glance.module("")
  let module = glimpse.load_module(glance_module, "some/module")

  let package = glimpse.Package("some_package", dict.new(), [])

  assert glimpse.filter_new_dependencies(module, package) == []
}

pub fn new_dependency_test() {
  let assert Ok(glance_module) = glance.module("import gleam/io")
  let module = glimpse.load_module(glance_module, "some/module")

  let package = glimpse.Package("some_package", dict.new(), [])

  assert glimpse.filter_new_dependencies(module, package) == ["gleam/io"]
}

pub fn old_dependency_test() {
  let assert Ok(glance_module) = glance.module("import gleam/io")
  let module = glimpse.load_module(glance_module, "some/module")

  let package =
    glimpse.Package(
      "some_package",
      dict.new() |> dict.insert("gleam/io", empty_module("gleam/io")),
      [],
    )

  assert glimpse.filter_new_dependencies(module, package) == []
}

pub fn one_old_one_new_dependency_test() {
  let assert Ok(glance_module) =
    glance.module(
      "import gleam/io
import gleam/list",
    )
  let module = glimpse.load_module(glance_module, "some/module")

  let package =
    glimpse.Package(
      "some_package",
      dict.new() |> dict.insert("gleam/io", empty_module("gleam/io")),
      [],
    )

  assert glimpse.filter_new_dependencies(module, package) == ["gleam/list"]
}
