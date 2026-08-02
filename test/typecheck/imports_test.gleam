import glance
import gleam/dict
import glimpse
import glimpse/internal/typecheck/types
import glimpse/typecheck
import typecheck/helpers

pub fn import_adds_function_to_env_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub fn bar() -> Nil {}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs)

  assert dict.size(main_env.definitions) == 8
  let assert Ok(foo_namespace) = dict.get(main_env.definitions, "foo")
  assert foo_namespace
    == types.NamespaceType(
      dict.from_list([
        #("bar", types.CallableType([], dict.new(), types.NilType)),
      ]),
      dict.new(),
    )

  assert dict.size(main_env.import_names) == 1
  let assert Ok(_) = dict.get(main_env.import_names, "foo")
}

pub fn import_no_add_private_function_to_env_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("fn bar() -> Nil {}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs)

  assert dict.size(main_env.definitions) == 8
  let assert Ok(foo_namespace) = dict.get(main_env.definitions, "foo")
  assert foo_namespace == types.NamespaceType(dict.new(), dict.new())

  assert dict.size(main_env.import_names) == 1
  let assert Ok(_) = dict.get(main_env.import_names, "foo")
}

pub fn import_adds_variant_to_env_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub type Foo {Foo}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs)

  assert dict.size(main_env.definitions) == 8
  let assert Ok(foo_namespace) = dict.get(main_env.definitions, "foo")
  assert foo_namespace
    == types.NamespaceType(
      dict.from_list([
        #("Foo", types.CustomType("main_module", "Foo", [])),
      ]),
      dict.from_list([#("Foo", types.CustomType("main_module", "Foo", []))]),
    )

  assert dict.size(main_env.import_names) == 1
  let assert Ok(_) = dict.get(main_env.import_names, "foo")
}

pub fn import_no_add_private_variant_to_env_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("type Foo {Foo}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) = glance.module("import foo")
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs)

  assert dict.size(main_env.definitions) == 8
  let assert Ok(foo_namespace) = dict.get(main_env.definitions, "foo")
  assert foo_namespace == types.NamespaceType(dict.from_list([]), dict.new())

  assert dict.size(main_env.import_names) == 1
  let assert Ok(_) = dict.get(main_env.import_names, "foo")
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
    )

  assert dict.size(main_env.definitions) == 9
  let assert Ok(foo_namespace) = dict.get(main_env.definitions, "foo")
  assert foo_namespace
    == types.NamespaceType(
      dict.from_list([
        #("bar", types.CallableType([], dict.new(), types.NilType)),
      ]),
      dict.new(),
    )

  assert dict.size(main_env.import_names) == 1
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
    )

  assert dict.size(main_env.definitions) == 9
  let assert Ok(foo_namespace) = dict.get(main_env.definitions, "foo")
  assert foo_namespace
    == types.NamespaceType(
      dict.from_list([
        #("Foo", types.CustomType("main_module", "Foo", [])),
      ]),
      dict.from_list([#("Foo", types.CustomType("main_module", "Foo", []))]),
    )

  assert dict.size(main_env.import_names) == 1
}
