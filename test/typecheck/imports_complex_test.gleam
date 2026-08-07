import glance
import gleam/dict
import gleam/option
import glimpse
import glimpse/error
import glimpse/internal/typecheck/types
import glimpse/target
import glimpse/typecheck
import typecheck/helpers

pub fn unqualified_value_import_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub fn bar() -> Int { 1 }")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo.{bar}")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs, target.Erlang)

  assert dict.get(main_env.definitions, "bar")
    == Ok(types.CallableType([], dict.new(), types.IntType))
}

pub fn unqualified_value_import_usable_in_body_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub fn bar() -> Int { 1 }")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) =
    glance.module(
      "import foo.{bar}
    fn main() -> Int { bar() }",
    )
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs, target.Erlang)

  assert dict.get(main_env.definitions, "main")
    == Ok(types.CallableType([], dict.new(), types.IntType))
}

pub fn imported_value_resolves_to_full_callable_type_test() {
  let #(_, foo_env) =
    helpers.ok_module_typecheck("pub fn map(x: Int) -> Int { x }")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo.{map}")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs, target.Erlang)

  assert dict.get(main_env.definitions, "map")
    == Ok(types.CallableType([types.IntType], dict.new(), types.IntType))
}

pub fn aliased_module_import_field_access_test() {
  let #(_, foo_env) =
    helpers.ok_module_typecheck("pub fn length(s: String) -> Int { 1 }")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) =
    glance.module(
      "import foo as s
    fn main() -> Int { s.length(\"hi\") }",
    )
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs, target.Erlang)

  assert dict.get(main_env.definitions, "main")
    == Ok(types.CallableType([], dict.new(), types.IntType))
}

pub fn unqualified_type_import_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub type Bar { Bar }")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) =
    glance.module(
      "import foo.{type Bar, Bar}
    fn f() -> Bar { Bar }",
    )
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs, target.Erlang)

  assert dict.get(main_env.custom_types, "Bar")
    == Ok(types.CustomType("main_module", "Bar", [], option.None))
}

pub fn unqualified_constructor_import_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub type Foo { Foo }")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo.{Foo}")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs, target.Erlang)

  assert dict.get(main_env.definitions, "Foo")
    == Ok(types.CustomType("main_module", "Foo", [], option.Some(0)))
}

pub fn renamed_unqualified_import_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub type Foo { Foo }")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo.{Foo as Baz}")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs, target.Erlang)

  assert dict.has_key(main_env.definitions, "Baz")
  assert dict.has_key(main_env.definitions, "Foo") == False
}

pub fn combined_value_and_type_import_test() {
  let #(_, foo_env) =
    helpers.ok_module_typecheck(
      "pub type Bar { Bar }
    pub fn make() -> Bar { Bar }",
    )

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) =
    glance.module(
      "import foo.{type Bar, make}
    fn f() -> Bar { make() }",
    )
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs, target.Erlang)

  assert dict.get(main_env.definitions, "f")
    == Ok(types.CallableType(
      [],
      dict.new(),
      types.CustomType("main_module", "Bar", [], option.None),
    ))
}

pub fn package_with_unqualified_import_test() {
  helpers.ok_package_check("main_module", fn(pkg) {
    case pkg {
      "main_module" ->
        Ok(
          "import foo.{bar}
        fn main() -> Int { bar() }",
        )
      "foo" -> Ok("pub fn bar() -> Int { 1 }")
      _ -> panic as "unexpected module in loader"
    }
  })
}

pub fn package_with_aliased_import_test() {
  helpers.ok_package_check("main_module", fn(pkg) {
    case pkg {
      "main_module" ->
        Ok(
          "import foo as f
        fn main() -> Int { f.bar() }",
        )
      "foo" -> Ok("pub fn bar() -> Int { 1 }")
      _ -> panic as "unexpected module in loader"
    }
  })
}

pub fn missing_import_returns_import_error_test() {
  let assert Ok(parsed) =
    glance.module("import missing\npub fn main() -> Nil {}")

  let main_module = glimpse.Module("main_module", parsed, ["missing"])
  let package =
    glimpse.Package(
      "main_module",
      dict.from_list([#("main_module", main_module)]),
      [],
    )

  let actual: Result(glimpse.Package, error.GlimpseError(Nil)) =
    typecheck.package(package, target.Erlang)
  assert actual == Error(error.ImportError(error.MissingImportError("missing")))
}

pub fn load_package_missing_module_returns_load_error_test() {
  let actual =
    glimpse.load_package("main_module", fn(name) {
      case name {
        "main_module" -> Ok("import missing/module\npub fn main() -> Nil {}")
        _ -> Error(Nil)
      }
    })
  assert actual == Error(error.LoadError(Nil))
}

pub fn src_importing_dev_dependency_is_rejected_test() {
  let assert Ok(parsed_main) =
    glance.module(
      "import devonly
    pub fn main() { devonly.x() }",
    )
  let assert Ok(parsed_devonly) = glance.module("pub fn x() -> Int { 1 }")
  let main_module = glimpse.Module("main_module", parsed_main, ["devonly"])
  let devonly_module = glimpse.Module("devonly", parsed_devonly, [])
  let package =
    glimpse.Package(
      "main_module",
      dict.from_list([
        #("main_module", main_module),
        #("devonly", devonly_module),
      ]),
      ["devonly"],
    )
  let actual: Result(glimpse.Package, error.GlimpseError(Nil)) =
    typecheck.package(package, target.Erlang)
  assert actual
    == Error(error.ImportError(error.SrcImportingDevDependency("main_module")))
}

pub fn dev_dependency_importing_dev_dependency_is_fine_test() {
  let assert Ok(parsed_dev) =
    glance.module(
      "import devonly
    pub fn main() { devonly.x() }",
    )
  let assert Ok(parsed_devonly) = glance.module("pub fn x() -> Int { 1 }")
  let assert Ok(parsed_main) = glance.module("pub fn main() { Nil }")
  let dev_module = glimpse.Module("dev", parsed_dev, ["devonly"])
  let devonly_module = glimpse.Module("devonly", parsed_devonly, [])
  let package =
    glimpse.Package(
      "main_module",
      dict.from_list([
        #("main_module", glimpse.Module("main_module", parsed_main, [])),
        #("dev", dev_module),
        #("devonly", devonly_module),
      ]),
      ["dev", "devonly"],
    )
  let actual: Result(glimpse.Package, error.GlimpseError(Nil)) =
    typecheck.package(package, target.Erlang)
  assert case actual {
    Ok(_) -> True
    Error(_) -> False
  }
}
