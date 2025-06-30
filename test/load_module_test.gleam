import glance
import glimpse

pub fn zero_dependency_test() {
  let assert Ok(glance_module) = glance.module("pub fn main() {}")

  let glimpse_module =
    glance_module
    |> glimpse.load_module("some/module")

  assert glimpse_module.name == "some/module"
  assert glimpse_module.dependencies == []
  assert glimpse_module.module == glance_module
}

pub fn unqualified_import_test() {
  let assert Ok(glance_module) =
    glance.module(
      "import gleam/io

    pub fn main() {}",
    )

  let glimpse_module =
    glance_module
    |> glimpse.load_module("some/module")

  assert glimpse_module.name == "some/module"
  assert glimpse_module.dependencies == ["gleam/io"]
  assert glimpse_module.module == glance_module
}
