import gleam/dict
import gleam/option
import glimpse/error
import glimpse/internal/typecheck/types
import typecheck/helpers

pub fn capture_partial_application_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "fn f(x: Int, y: Int) -> Int { x + y }
    fn g(x: Int) -> Int {
      let h = f(1, _)
      h(x)
    }",
    )

  assert dict.get(env.scope.definitions, "g")
    == Ok(types.CallableType([types.IntType], dict.new(), types.IntType))
}

pub fn capture_second_argument_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "fn f(x: Int, y: Int) -> Int { x + y }
    fn g(y: Int) -> Int {
      let h = f(_, y)
      h(1)
    }",
    )

  assert dict.get(env.scope.definitions, "g")
    == Ok(types.CallableType([types.IntType], dict.new(), types.IntType))
}

pub fn capture_more_arguments_after_hole_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "fn f(x: Int, y: Int, z: Int) -> Int { x + y + z }
    fn g(x: Int, z: Int) -> Int {
      let h = f(x, _, z)
      h(2)
    }",
    )

  assert dict.get(env.scope.definitions, "g")
    == Ok(types.CallableType(
      [types.IntType, types.IntType],
      dict.new(),
      types.IntType,
    ))
}

pub fn capture_no_arguments_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "fn f(x: Int) -> Int { x }
    fn g(x: Int) -> Int {
      let h = f(_)
      h(x)
    }",
    )

  assert dict.get(env.scope.definitions, "g")
    == Ok(types.CallableType([types.IntType], dict.new(), types.IntType))
}

pub fn capture_as_callback_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "fn apply(f: fn(Int) -> Int, x: Int) -> Int { f(x) }
    fn f(x: Int, y: Int) -> Int { x + y }
    fn g(x: Int) -> Int { apply(f(1, _), x) }",
    )

  assert dict.get(env.scope.definitions, "g")
    == Ok(types.CallableType([types.IntType], dict.new(), types.IntType))
}

pub fn capture_generic_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "fn pair(a: a, b: b) -> #(a, b) { #(a, b) }
    fn g(x: Int) -> Int {
      let h = pair(x, _)
      let #(a, b) = h(1)
      a + b
    }",
    )

  assert dict.get(env.scope.definitions, "g")
    == Ok(types.CallableType([types.IntType], dict.new(), types.IntType))
}

pub fn let_bound_capture_used_at_one_type_is_fine_test() {
  helpers.ok_module_typecheck(
    "pub type Box(a) { Box(a) }
  pub fn wrap(x: a) -> Box(a) { Box(x) }
  pub fn apply2(f: fn(b) -> Box(b), x: b) -> Box(b) { f(x) }
  pub fn f() -> #(Box(Int), Box(Int)) {
    let g = wrap(_)
    #(apply2(g, 1), apply2(g, 2))
  }",
  )
}

pub fn let_bound_capture_used_at_two_types_is_rejected_test() {
  // A capture is evaluated once, so when bound with `let` it is monomorphic:
  // its type variables unify on first use. Real Gleam rejects using the same
  // let-bound capture at two different types, even though each direct capture
  // expression (`wrap(_)(1)`, `wrap(_)(True)`) is polymorphic.
  assert helpers.error_module_typecheck(
    "pub type Box(a) { Box(a) }
  pub fn wrap(x: a) -> Box(a) { Box(x) }
  pub fn f() -> #(Box(Int), Box(Bool)) {
    let g = wrap(_)
    #(g(1), g(True))
  }",
    )
    == error.InvalidArguments("(var_0)", "(Bool)")
}

pub fn direct_capture_used_at_two_types_is_fine_test() {
  // Each direct capture expression is a fresh evaluation, so both stay
  // polymorphic.
  helpers.ok_module_typecheck(
    "pub type Box(a) { Box(a) }
  pub fn wrap(x: a) -> Box(a) { Box(x) }
  pub fn f() -> #(Box(Int), Box(Bool)) {
    #(wrap(_)(1), wrap(_)(True))
  }",
  )
}

pub fn capture_labeled_hole_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "fn f(x x: Int, y y: Int) -> Int { x + y }
    fn g() -> Int {
      let h = f(x: _, y: 1)
      h(2)
    }",
    )

  assert dict.get(env.scope.definitions, "g")
    == Ok(types.CallableType([], dict.new(), types.IntType))
}

pub fn capture_wrong_arg_type_test() {
  assert helpers.error_module_typecheck(
      "fn f(x: Int, y: Int) -> Int { x + y }
    fn g() -> Int {
      let h = f(\"s\", _)
      h(1)
    }",
    )
    == error.InvalidType("String", "Int", "in type mismatch")
}

pub fn capture_wrong_call_arg_type_test() {
  assert helpers.error_module_typecheck(
      "fn f(x: Int, y: Int) -> Int { x + y }
    fn g() -> Int {
      let h = f(1, _)
      h(\"s\")
    }",
    )
    == error.InvalidArguments("(Int)", "(String)")
}

pub fn capture_lambda_in_pipe_test() {
  let #(_module, env) =
    helpers.ok_module_typecheck(
      "pub type Upload { Upload(file_name: String) }
    fn fold(
      items: List(#(String, Upload)),
      acc: BitArray,
      fun: fn(BitArray, #(String, Upload)) -> BitArray,
    ) -> BitArray { acc }
    fn build(files: List(#(String, Upload))) -> BitArray {
      <<>> |> fold(files, _, fn(acc, file) {
        <<acc:bits, file.0:utf8, file.1.file_name:utf8>>
      })
    }",
    )

  assert dict.get(env.scope.definitions, "build")
    == Ok(types.CallableType(
      [
        types.CustomType(
          "gleam",
          "List",
          [
            types.TupleType([
              types.StringType,
              types.CustomType("main_module", "Upload", [], option.None),
            ]),
          ],
          option.None,
        ),
      ],
      dict.new(),
      types.BitArrayType,
    ))
}
