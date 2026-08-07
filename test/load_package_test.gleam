import glance
import gleam/dict
import glimpse
import glimpse/error

pub fn ok_module(contents: String) -> glance.Module {
  let assert Ok(module) = glance.module(contents)
  module
}

pub fn no_dependency_package_test() {
  let assert Ok(result) =
    glimpse.load_package("main_module", fn(_) { Ok("pub fn main() {}") })

  assert result
    == glimpse.Package(
      "main_module",
      dict.from_list([
        #(
          "main_module",
          glimpse.Module("main_module", ok_module("pub fn main() {}"), []),
        ),
      ]),
      [],
    )
}

pub fn single_dependency_package_test() {
  let assert Ok(loaded_package) =
    glimpse.load_package("main_module", fn(mod) {
      case mod {
        "main_module" ->
          Ok(
            "import gleam/io
    pub fn main() {}",
          )
        "gleam/io" -> Ok("")
        _ -> Error("unexpected module")
      }
    })

  assert loaded_package.name == "main_module"

  assert dict.size(loaded_package.modules) == 2

  expect_modules_equal(
    loaded_package,
    "main_module",
    ["gleam/io"],
    "import gleam/io
    pub fn main() {}",
  )

  expect_modules_equal(loaded_package, "gleam/io", [], "")
}

pub fn diamond_dependency_package_test() {
  let assert Ok(loaded_package) =
    glimpse.load_package("main_module", fn(mod) {
      case mod {
        "main_module" -> Ok("import a\nimport b")
        "a" | "b" -> Ok("import gleam/io")
        "gleam/io" -> Ok("")
        _ -> Error("unexpected module")
      }
    })

  assert loaded_package.name == "main_module"

  assert dict.size(loaded_package.modules) == 4

  expect_modules_equal(
    loaded_package,
    "main_module",
    ["b", "a"],
    "import a
import b",
  )

  expect_modules_equal(loaded_package, "a", ["gleam/io"], "import gleam/io")
  expect_modules_equal(loaded_package, "b", ["gleam/io"], "import gleam/io")
  expect_modules_equal(loaded_package, "gleam/io", [], "")
}

pub fn loader_error_test() {
  let assert Error(error) =
    glimpse.load_package("main_module", fn(_mod) { Error("I am error") })
  assert error == error.LoadError("I am error")
}

fn expect_modules_equal(
  package: glimpse.Package,
  name: String,
  expected_dependencies: List(String),
  expected_module_contents: String,
) -> Nil {
  let assert Ok(module) = dict.get(package.modules, name)

  assert module.name == name

  assert module.dependencies == expected_dependencies

  let assert Ok(expected_module) = glance.module(expected_module_contents)
  assert module.module == expected_module

  Nil
}
