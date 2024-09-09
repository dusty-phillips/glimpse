import glance
import gleam/dict
import gleeunit/should
import glimpse

pub fn ok_module(contents: String) -> glance.Module {
  glance.module(contents)
  |> should.be_ok
}

pub fn no_dependency_package_test() {
  glimpse.load_package("main_module", fn(_) { Ok("pub fn main() {}") })
  |> should.be_ok
  |> should.equal(glimpse.Package(
    "main_module",
    dict.from_list([
      #(
        "main_module",
        glimpse.Module("main_module", ok_module("pub fn main() {}"), []),
      ),
    ]),
  ))
}

pub fn single_dependency_package_test() {
  let loaded_package =
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
    |> should.be_ok

  loaded_package.name
  |> should.equal("main_module")

  loaded_package.modules
  |> dict.size
  |> should.equal(2)

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
  let loaded_package =
    glimpse.load_package("main_module", fn(mod) {
      case mod {
        "main_module" -> Ok("import a\nimport b")
        "a" | "b" -> Ok("import gleam/io")
        "gleam/io" -> Ok("")
        _ -> Error("unexpected module")
      }
    })
    |> should.be_ok

  loaded_package.name
  |> should.equal("main_module")

  loaded_package.modules
  |> dict.size
  |> should.equal(4)

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
  glimpse.load_package("main_module", fn(_mod) { Error("I am error") })
  |> should.be_error
  |> should.equal(glimpse.LoadError("I am error"))
}

fn expect_modules_equal(
  package: glimpse.Package,
  name: String,
  expected_dependencies: List(String),
  expected_module_contents: String,
) -> Nil {
  let module =
    package.modules
    |> dict.get(name)
    |> should.be_ok

  module.name
  |> should.equal(name)

  module.dependencies
  |> should.equal(expected_dependencies)

  module.module
  |> should.equal(expected_module_contents |> glance.module |> should.be_ok)

  Nil
}
