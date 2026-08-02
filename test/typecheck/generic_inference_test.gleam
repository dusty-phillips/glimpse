import glance
import gleam/dict
import gleam/option
import glimpse/internal/typecheck/types
import typecheck/helpers

pub fn higher_order_apply_test() {
  let #(module, env) =
    helpers.ok_module_typecheck("fn apply(f: fn(a) -> b, x: a) -> b { f(x) }")

  let assert Ok(apply_type) = dict.get(env.definitions, "apply")
  let assert types.GenericCallableType(parameters, labels, return, _) =
    apply_type

  assert parameters
    == [
      types.CallableType(
        [types.GenericTypeVariable("a")],
        dict.new(),
        types.GenericTypeVariable("b"),
      ),
      types.GenericTypeVariable("a"),
    ]
  assert labels == dict.new()
  assert return == types.GenericTypeVariable("b")

  let assert [apply_def] = module.module.functions
  let assert option.Some(glance.VariableType(_, "b")) =
    apply_def.definition.return
}

pub fn higher_order_apply_concrete_test() {
  let #(module, env) =
    helpers.ok_module_typecheck(
      "fn apply(f: fn(a) -> b, x: a) -> b { f(x) }
    fn use_it() -> String {
      apply(fn(n: Int) { \"hi\" }, 5)
    }",
    )

  assert dict.get(env.definitions, "use_it")
    == Ok(types.CallableType([], dict.new(), types.StringType))

  let assert [use_it_def, _] = module.module.functions
  let assert option.Some(glance.NamedType(_, "String", option.None, [])) =
    use_it_def.definition.return
}

pub fn recursive_generic_map_list_test() {
  let #(module, env) =
    helpers.ok_module_typecheck(
      "fn map_list(xs: List(a), f: fn(a) -> b) -> List(b) {
      case xs {
        [x, ..rest] -> [f(x), ..map_list(rest, f)]
        [] -> []
      }
    }",
    )

  let assert Ok(map_list_type) = dict.get(env.definitions, "map_list")
  let assert types.GenericCallableType(parameters, labels, return, _) =
    map_list_type

  assert parameters
    == [
      types.ListType(types.GenericTypeVariable("a")),
      types.CallableType(
        [types.GenericTypeVariable("a")],
        dict.new(),
        types.GenericTypeVariable("b"),
      ),
    ]
  assert labels == dict.new()
  assert return == types.ListType(types.GenericTypeVariable("b"))

  let assert [map_list_def] = module.module.functions
  let assert option.Some(glance.NamedType(
    _,
    "List",
    option.None,
    [glance.VariableType(_, "b")],
  )) = map_list_def.definition.return
}

pub fn parametric_type_generic_test() {
  let #(module, env) =
    helpers.ok_module_typecheck(
      "type Box(a) { Box(value: a) }
    fn make(x: a) -> Box(a) { Box(x) }
    fn use_it(x: Int) -> Box(Int) { make(x) }",
    )

  let assert Ok(make_type) = dict.get(env.definitions, "make")
  let assert types.GenericCallableType(parameters, labels, return, _) =
    make_type

  assert parameters == [types.GenericTypeVariable("a")]
  assert labels == dict.new()
  assert return
    == types.CustomType("main_module", "Box", [types.GenericTypeVariable("a")])

  assert dict.get(env.definitions, "use_it")
    == Ok(types.CallableType(
      [types.IntType],
      dict.new(),
      types.CustomType("main_module", "Box", [types.IntType]),
    ))

  let assert [use_it_def, _] = module.module.functions
  let assert option.Some(glance.NamedType(
    _,
    "Box",
    option.None,
    [glance.NamedType(_, "Int", option.None, [])],
  )) = use_it_def.definition.return
}
