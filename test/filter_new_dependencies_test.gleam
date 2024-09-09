import glance
import gleam/dict
import gleeunit/should
import glimpse

fn empty_module(name: String) -> glimpse.Module {
  glance.module("")
  |> should.be_ok
  |> glimpse.Module(name, _, [])
}

pub fn no_dependencies_test() {
  let module =
    glance.module("")
    |> should.be_ok
    |> glimpse.load_module("some/module")

  let package = glimpse.Package("some_package", dict.new())

  glimpse.filter_new_dependencies(module, package)
  |> should.equal([])
}

pub fn new_dependency_test() {
  let module =
    glance.module("import gleam/io")
    |> should.be_ok
    |> glimpse.load_module("some/module")

  let package = glimpse.Package("some_package", dict.new())

  glimpse.filter_new_dependencies(module, package)
  |> should.equal(["gleam/io"])
}

pub fn old_dependency_test() {
  let module =
    glance.module("import gleam/io")
    |> should.be_ok
    |> glimpse.load_module("some/module")

  let package =
    glimpse.Package(
      "some_package",
      dict.new() |> dict.insert("gleam/io", empty_module("gleam/io")),
    )

  glimpse.filter_new_dependencies(module, package)
  |> should.equal([])
}

pub fn one_old_one_new_dependency_test() {
  let module =
    glance.module(
      "import gleam/io
import gleam/list",
    )
    |> should.be_ok
    |> glimpse.load_module("some/module")

  let package =
    glimpse.Package(
      "some_package",
      dict.new() |> dict.insert("gleam/io", empty_module("gleam/io")),
    )

  glimpse.filter_new_dependencies(module, package)
  |> should.equal(["gleam/list"])
}
