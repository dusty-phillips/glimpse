import glance
import gleam/dict
import glimpse
import glimpse/error
import glimpse/internal/typecheck/types
import glimpse/typecheck
import typecheck/helpers

pub fn unqualified_value_import_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub fn bar() -> Int { 1 }")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo.{bar}")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs)

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
    |> typecheck.module(other_envs)

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
    |> typecheck.module(other_envs)

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
    |> typecheck.module(other_envs)

  assert dict.get(main_env.definitions, "main")
    == Ok(types.CallableType([], dict.new(), types.IntType))
}

pub fn unqualified_type_import_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub type Bar { Bar }")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) =
    glance.module(
      "import foo.{type Bar, Bar}
    fn f() -> Bar { Bar() }",
    )
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs)

  assert dict.get(main_env.custom_types, "Bar")
    == Ok(types.CustomType("main_module", "Bar", []))
}

pub fn unqualified_constructor_import_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub type Foo { Foo }")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo.{Foo}")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs)

  assert dict.get(main_env.definitions, "Foo")
    == Ok(types.CallableType(
      [],
      dict.new(),
      types.CustomType("main_module", "Foo", []),
    ))
}

pub fn renamed_unqualified_import_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub type Foo { Foo }")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo.{Foo as Baz}")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs)

  assert dict.has_key(main_env.definitions, "Baz")
  assert dict.has_key(main_env.definitions, "Foo") == False
}

pub fn combined_value_and_type_import_test() {
  let #(_, foo_env) =
    helpers.ok_module_typecheck(
      "pub type Bar { Bar }
    pub fn make() -> Bar { Bar() }",
    )

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) =
    glance.module(
      "import foo.{type Bar, make}
    fn f() -> Bar { make() }",
    )
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs)

  assert dict.get(main_env.definitions, "f")
    == Ok(types.CallableType(
      [],
      dict.new(),
      types.CustomType("main_module", "Bar", []),
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
    )

  let actual: Result(glimpse.Package, error.GlimpseError(Nil)) =
    typecheck.package(package)
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
