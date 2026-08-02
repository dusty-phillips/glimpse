import glance
import gleam/dict
import gleam/option
import glimpse
import glimpse/error
import glimpse/internal/typecheck/types
import glimpse/typecheck
import typecheck/helpers

pub fn parametric_custom_type_def_test() {
  let env = "type Box(a) { Box(value: a) }" |> helpers.ok_custom_type

  assert dict.get(env.custom_types, "Box")
    == Ok(
      types.CustomType("main_module", "Box", [
        types.GenericTypeVariable("a"),
      ]),
    )

  assert dict.get(env.definitions, "Box")
    == Ok(types.GenericCallableType(
      [types.GenericTypeVariable("a")],
      dict.from_list([#("value", 0)]),
      types.CustomType("main_module", "Box", [
        types.GenericTypeVariable("a"),
      ]),
      glance.Function(
        glance.Span(-1, -1),
        "",
        glance.Private,
        [],
        option.None,
        [],
      ),
    ))
}

pub fn parametric_annotation_and_constructor_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "type Box(a) { Box(value: a) }
    fn mk(x: Int) {
      Box(x)
    }",
    )

  let assert [mk_def] = module.module.functions
  assert mk_def.definition.return
    == option.Some(
      glance.NamedType(glance.Span(-1, -1), "Box", option.None, [
        glance.NamedType(glance.Span(-1, -1), "Int", option.None, []),
      ]),
    )
}

pub fn parametric_annotation_mismatch_test() {
  assert helpers.error_module_typecheck(
      "type Box(a) { Box(value: a) }
    fn mk(x: String) -> Box(Int) {
      Box(x)
    }",
    )
    == error.InvalidReturnType(
      "mk",
      "main_module.Box(String)",
      "main_module.Box(Int)",
    )
}

pub fn parametric_pattern_resolves_field_type_test() {
  let #(module, env) =
    helpers.ok_module_typecheck(
      "type Box(a) { Box(value: a) }
    fn unbox(b: Box(Int)) -> Int {
      case b {
        Box(v) -> v
      }
    }",
    )

  assert dict.get(env.definitions, "unbox")
    == Ok(types.CallableType(
      [types.CustomType("main_module", "Box", [types.IntType])],
      dict.new(),
      types.IntType,
    ))

  let assert [unbox_def] = module.module.functions
  let assert option.Some(glance.NamedType(_, "Int", option.None, [])) =
    unbox_def.definition.return
}

pub fn parametric_pattern_field_type_flows_test() {
  assert helpers.error_module_typecheck(
      "type Box(a) { Box(value: a) }
    fn unbox(b: Box(String)) -> Int {
      case b {
        Box(v) -> v
      }
    }",
    )
    == error.InvalidReturnType("unbox", "String", "Int")
}

pub fn parametric_generic_identity_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "type Box(a) { Box(value: a) }
    fn map(b: Box(a), f: fn(a) -> a) -> Box(a) {
      case b {
        Box(v) -> Box(f(v))
      }
    }
    fn use_it(x: Int) -> Int {
      case map(Box(x), fn(y: Int) { y }) {
        Box(v) -> v
      }
    }",
    )

  assert dict.get(env.definitions, "use_it")
    == Ok(types.CallableType([types.IntType], dict.new(), types.IntType))
}

pub fn parametric_bare_type_arity_error_test() {
  assert helpers.error_module_typecheck(
      "type Box(a) { Box(value: a) }
    fn foo(x: Int) -> Box {
      Box(x)
    }",
    )
    == error.InvalidType(
      "Box",
      "main_module.Box(a)",
      "wrong number of type parameters: expected 1, got 0",
    )
}

pub fn parametric_wrong_type_parameter_count_test() {
  assert helpers.error_module_typecheck(
      "type Box(a) { Box(value: a) }
    fn foo(x: Int) -> Box(Int, Int) {
      Box(x)
    }",
    )
    == error.InvalidType(
      "Box",
      "main_module.Box(a)",
      "wrong number of type parameters: expected 1, got 2",
    )
}

pub fn parametric_qualified_cross_module_test() {
  helpers.ok_package_check("main_module", fn(pkg) {
    case pkg {
      "main_module" ->
        Ok(
          "import foo
        fn use_it(x: Int) -> Int {
          case foo.make(x) {
            foo.Box(v) -> v
          }
        }",
        )
      "foo" ->
        Ok(
          "pub type Box(a) { Box(value: a) }
        pub fn make(x: a) -> Box(a) {
          Box(x)
        }",
        )
      _ -> panic as "only two modules in this test"
    }
  })
}

pub fn parametric_unqualified_cross_module_test() {
  let #(_, foo_env) =
    helpers.ok_module_typecheck(
      "pub type Box(a) { Box(value: a) }
    pub fn make(x: a) -> Box(a) { Box(x) }
    pub fn unbox(b: Box(a)) -> a {
      case b {
        Box(v) -> v
      }
    }",
    )

  let other_envs = dict.from_list([#("foo", foo_env)])

  let assert Ok(parsed_module) =
    glance.module(
      "import foo.{type Box, Box, make, unbox}
    fn use_it(b: Box(Int)) -> Int {
      unbox(b)
    }",
    )
  let assert Ok(#(_, main_env)) =
    glimpse.Module("main_module", parsed_module, ["foo"])
    |> typecheck.module(other_envs)

  assert dict.get(main_env.definitions, "use_it")
    == Ok(types.CallableType(
      [types.CustomType("main_module", "Box", [types.IntType])],
      dict.new(),
      types.IntType,
    ))
}
