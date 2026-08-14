import glance
import gleam/dict
import gleam/option
import glimpse
import glimpse/error
import glimpse/internal/typecheck/types
import glimpse/target
import glimpse/typecheck

import typecheck/helpers

pub fn import_adds_function_to_env_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub fn bar() -> Nil {}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs, target.Erlang, True)

  assert dict.size(main_env.scope.definitions) == 7
  let assert Ok(foo_namespace) =
    dict.get(main_env.imports.module_imports, "foo")
  assert foo_namespace
    == types.NamespaceType(
      dict.from_list([
        #("bar", types.CallableType([], dict.new(), types.NilType)),
      ]),
      dict.new(),
    )

  assert dict.size(main_env.imports.import_names) == 1
  let assert Ok(_) = dict.get(main_env.imports.import_names, "foo")
}

pub fn import_no_add_private_function_to_env_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("fn bar() -> Nil {}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs, target.Erlang, True)

  assert dict.size(main_env.scope.definitions) == 7
  let assert Ok(foo_namespace) =
    dict.get(main_env.imports.module_imports, "foo")
  assert foo_namespace == types.NamespaceType(dict.new(), dict.new())

  assert dict.size(main_env.imports.import_names) == 1
  let assert Ok(_) = dict.get(main_env.imports.import_names, "foo")
}

pub fn import_adds_variant_to_env_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub type Foo {Foo}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs, target.Erlang, True)

  assert dict.size(main_env.scope.definitions) == 7
  let assert Ok(foo_namespace) =
    dict.get(main_env.imports.module_imports, "foo")
  assert foo_namespace
    == types.NamespaceType(
      dict.from_list([
        #("Foo", types.CustomType("main_module", "Foo", [], option.Some(0))),
      ]),
      dict.from_list([
        #("Foo", types.CustomType("main_module", "Foo", [], option.None)),
      ]),
    )

  assert dict.size(main_env.imports.import_names) == 1
  let assert Ok(_) = dict.get(main_env.imports.import_names, "foo")
}

pub fn import_no_add_private_variant_to_env_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("type Foo {Foo}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs, target.Erlang, True)

  assert dict.size(main_env.scope.definitions) == 7
  let assert Ok(foo_namespace) =
    dict.get(main_env.imports.module_imports, "foo")
  assert foo_namespace == types.NamespaceType(dict.from_list([]), dict.new())

  assert dict.size(main_env.imports.import_names) == 1
  let assert Ok(_) = dict.get(main_env.imports.import_names, "foo")
}

pub fn import_call_function_field_access_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub fn bar() -> Nil {}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(glance_module) =
    glance.module(
      "import foo
    pub fn main() -> Nil {
      foo.bar()
    }",
    )
  let assert Ok(#(_, main_env)) =
    typecheck.module(
      glimpse.Module("main_module", glance_module, ["foo"]),
      other_envs,
      target.Erlang,
      True,
    )

  assert dict.size(main_env.scope.definitions) == 8
  let assert Ok(foo_namespace) =
    dict.get(main_env.imports.module_imports, "foo")
  assert foo_namespace
    == types.NamespaceType(
      dict.from_list([
        #("bar", types.CallableType([], dict.new(), types.NilType)),
      ]),
      dict.new(),
    )

  assert dict.size(main_env.imports.import_names) == 1
}

pub fn variant_call_function_field_access_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub type Foo {Foo}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(glance_module) =
    glance.module(
      "import foo
    pub fn main() -> foo.Foo {
    foo.Foo
    }",
    )
  let assert Ok(#(_, main_env)) =
    typecheck.module(
      glimpse.Module("main_module", glance_module, ["foo"]),
      other_envs,
      target.Erlang,
      True,
    )

  assert dict.size(main_env.scope.definitions) == 8
  let assert Ok(foo_namespace) =
    dict.get(main_env.imports.module_imports, "foo")
  assert foo_namespace
    == types.NamespaceType(
      dict.from_list([
        #("Foo", types.CustomType("main_module", "Foo", [], option.Some(0))),
      ]),
      dict.from_list([
        #("Foo", types.CustomType("main_module", "Foo", [], option.None)),
      ]),
    )

  assert dict.size(main_env.imports.import_names) == 1
}

pub fn duplicate_type_import_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "import gleam/option.{type Option, type Option}
    pub fn main() -> Nil {
      Nil
    }",
    )
    == error.DuplicateDefinition("Option")
}

pub fn duplicate_value_import_is_rejected_test() {
  assert helpers.error_module_typecheck(
      "import gleam/option.{None, None}
    pub fn main() -> Nil {
      Nil
    }",
    )
    == error.DuplicateImport("None")
}

pub fn opaque_variant_referenced_in_constant_is_fine_test() {
  let assert Ok(dep_module) =
    glance.module(
      "pub opaque type Restart {
  Permanent
  Transient
}",
    )
  let assert Ok(#(_, dep_env)) =
    typecheck.module(
      glimpse.Module("other/package", dep_module, []),
      dict.new(),
      target.Erlang,
      False,
    )
  let assert Ok(main_module) =
    glance.module(
      "import other/package

const default_strategy = package.Transient

pub fn main() -> Nil {
  Nil
}",
    )
  let assert Ok(_) =
    typecheck.module(
      glimpse.Module("main_module", main_module, ["other/package"]),
      dict.new() |> dict.insert("other/package", dep_env),
      target.Erlang,
      True,
    )
}

pub fn opaque_variant_referenced_in_function_body_is_rejected_test() {
  let assert Ok(dep_module) =
    glance.module(
      "pub opaque type Restart {
  Permanent
  Transient
}",
    )
  let assert Ok(#(_, dep_env)) =
    typecheck.module(
      glimpse.Module("other/package", dep_module, []),
      dict.new(),
      target.Erlang,
      False,
    )
  let assert Ok(main_module) =
    glance.module(
      "import other/package

pub fn f() -> package.Restart {
  package.Transient
}

pub fn main() -> Nil {
  Nil
}",
    )
  let assert Error(err) =
    typecheck.module(
      glimpse.Module("main_module", main_module, ["other/package"]),
      dict.new() |> dict.insert("other/package", dep_env),
      target.Erlang,
      True,
    )
  assert err == error.InvalidName("Transient")
}

pub fn fn_body_referencing_private_cross_module_fn_with_constant_is_rejected_test() {
  let assert Ok(dep_module) = glance.module("fn f() -> Int {\n  1\n}")
  let assert Ok(#(_, dep_env)) =
    typecheck.module(
      glimpse.Module("other/package", dep_module, []),
      dict.new(),
      target.Erlang,
      False,
    )
  let assert Ok(main_module) =
    glance.module(
      "import other/package

const x = 1

pub fn main() -> Int {
  package.f()
}",
    )
  let assert Error(err) =
    typecheck.module(
      glimpse.Module("main_module", main_module, ["other/package"]),
      dict.new() |> dict.insert("other/package", dep_env),
      target.Erlang,
      True,
    )
  assert err == error.InvalidName("f")
}

pub fn fn_body_referencing_public_cross_module_fn_with_constant_is_fine_test() {
  let assert Ok(dep_module) = glance.module("pub fn f() -> Int {\n  1\n}")
  let assert Ok(#(_, dep_env)) =
    typecheck.module(
      glimpse.Module("other/package", dep_module, []),
      dict.new(),
      target.Erlang,
      False,
    )
  let assert Ok(main_module) =
    glance.module(
      "import other/package

const x = 1

pub fn main() -> Int {
  package.f()
}",
    )
  let assert Ok(#(_, _)) =
    typecheck.module(
      glimpse.Module("main_module", main_module, ["other/package"]),
      dict.new() |> dict.insert("other/package", dep_env),
      target.Erlang,
      True,
    )
}
