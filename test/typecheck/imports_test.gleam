import glance
import gleam/dict
import gleeunit/should
import glimpse
import glimpse/internal/typecheck/types
import glimpse/typecheck
import typecheck/assertions
import typecheck/helpers

pub fn import_adds_function_to_env_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub fn bar() -> Nil {}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let #(_, main_env) =
    glance.module("import foo")
    |> should.be_ok
    |> glimpse.Module("main_module", _, ["foo"])
    |> typecheck.module(other_envs)
    |> should.be_ok

  main_env.definitions
  |> assertions.should_have_dict_size(1)
  |> dict.get("foo")
  |> should.be_ok
  |> should.equal(
    types.NamespaceType(
      dict.from_list([
        #("bar", types.CallableType([], dict.new(), types.NilType)),
      ]),
    ),
  )
}

pub fn import_no_add_private_function_to_env_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("fn bar() -> Nil {}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let #(_, main_env) =
    glance.module("import foo")
    |> should.be_ok
    |> glimpse.Module("main_module", _, ["foo"])
    |> typecheck.module(other_envs)
    |> should.be_ok

  main_env.definitions
  |> assertions.should_have_dict_size(1)
  |> dict.get("foo")
  |> should.be_ok
  |> should.equal(types.NamespaceType(dict.new()))
}

pub fn import_adds_variant_to_env_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub type Foo {Foo}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let #(_, main_env) =
    glance.module("import foo")
    |> should.be_ok
    |> glimpse.Module("main_module", _, ["foo"])
    |> typecheck.module(other_envs)
    |> should.be_ok

  main_env.definitions
  |> assertions.should_have_dict_size(1)
  |> dict.get("foo")
  |> should.be_ok
  |> should.equal(
    types.NamespaceType(
      dict.from_list([
        #("Foo", types.CallableType([], dict.new(), types.CustomType("Foo"))),
      ]),
    ),
  )
}

pub fn import_no_add_private_variant_to_env_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("type Foo {Foo}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let #(_, main_env) =
    glance.module("import foo")
    |> should.be_ok
    |> glimpse.Module("main_module", _, ["foo"])
    |> typecheck.module(other_envs)
    |> should.be_ok

  main_env.definitions
  |> assertions.should_have_dict_size(1)
  |> dict.get("foo")
  |> should.be_ok
  |> should.equal(types.NamespaceType(dict.from_list([])))
}

pub fn import_call_function_field_access_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub fn bar() -> Nil {}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let #(_, main_env) =
    glance.module(
      "import foo
    pub fn main() -> Nil {
      foo.bar()
    }",
    )
    |> should.be_ok
    |> glimpse.Module("main_module", _, ["foo"])
    |> typecheck.module(other_envs)
    |> should.be_ok

  main_env.definitions
  |> assertions.should_have_dict_size(2)
  |> dict.get("foo")
  |> should.be_ok
  |> should.equal(
    types.NamespaceType(
      dict.from_list([
        #("bar", types.CallableType([], dict.new(), types.NilType)),
      ]),
    ),
  )
}

pub fn variant_call_function_field_access_test() {
  let #(_, foo_env) = helpers.ok_module_typecheck("pub type Foo {Foo}")

  let other_envs = dict.from_list([#("foo", foo_env)])

  let #(_, main_env) =
    glance.module(
      "import foo
    pub fn main() -> Nil {
    foo.Foo()
    Nil
    }",
    )
    |> should.be_ok
    |> glimpse.Module("main_module", _, ["foo"])
    |> typecheck.module(other_envs)
    |> should.be_ok

  main_env.definitions
  |> assertions.should_have_dict_size(2)
  |> dict.get("foo")
  |> should.be_ok
  |> should.equal(
    types.NamespaceType(
      dict.from_list([
        #("Foo", types.CallableType([], dict.new(), types.CustomType("Foo"))),
      ]),
    ),
  )
}
