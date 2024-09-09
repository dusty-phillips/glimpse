import glance
import gleeunit/should
import glimpse

pub fn zero_dependency_test() {
  let glance_module =
    "pub fn main() {}"
    |> glance.module
    |> should.be_ok

  let glimpse_module =
    glance_module
    |> glimpse.load_module("some/module")

  should.equal(glimpse_module.name, "some/module")
  should.equal(glimpse_module.dependencies, [])
  should.equal(glimpse_module.module, glance_module)
}

pub fn unqualified_import_test() {
  let glance_module =
    "import gleam/io

    pub fn main() {}"
    |> glance.module
    |> should.be_ok

  let glimpse_module =
    glance_module
    |> glimpse.load_module("some/module")

  should.equal(glimpse_module.name, "some/module")
  should.equal(glimpse_module.dependencies, ["gleam/io"])
  should.equal(glimpse_module.module, glance_module)
}
