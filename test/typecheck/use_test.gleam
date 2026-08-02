import typecheck/helpers

/// The `use` statement desugars to `f(args, fn(..) { .. })`, so the enclosing
/// block's type is the use function's return type, NOT the callback's return
/// type. This is the shape of glance's `until`/`variants`, where the use
/// function returns a 3-tuple but its callback returns a 2-tuple.
pub fn use_returns_use_function_return_test() {
  let #(_module, _env) =
    helpers.ok_module_typecheck(
      "fn until(
        limit: Int,
        acc: String,
        tokens: List(Int),
        callback: fn(String, List(Int)) -> Result(#(String, List(Int)), Nil),
      ) -> Result(#(String, Int, List(Int)), Nil) {
        case callback(acc, tokens) {
          Ok(#(acc, tokens)) -> Ok(#(acc, limit, tokens))
          Error(e) -> Error(e)
        }
      }
    fn foo() -> Result(#(String, Int, List(Int)), Nil) {
      use acc, tokens <- until(5, \"a\", [1, 2])
      Ok(#(acc, tokens))
    }",
    )
}

/// A `use` statement whose function returns the same type as its callback, as
/// with `result.try`. Nested uses must typecheck and the final expression must
/// be the callback body.
pub fn use_nested_result_chain_test() {
  let #(_module, _env) =
    helpers.ok_module_typecheck(
      "fn and_then(x: Result(a, e), f: fn(a) -> Result(b, e)) -> Result(b, e) {
        case x {
          Ok(value) -> f(value)
          Error(error) -> Error(error)
        }
      }
    fn foo() -> Result(Int, Nil) {
      use a <- and_then(Ok(1))
      use b <- and_then(Ok(2))
      Ok(a + b)
    }",
    )
}

/// A `use` statement in the middle of a block, after a let binding. The block's
/// type is still the use function's return type.
pub fn use_after_let_test() {
  let #(_module, _env) =
    helpers.ok_module_typecheck(
      "fn and_then(x: Result(a, e), f: fn(a) -> Result(b, e)) -> Result(b, e) {
        case x {
          Ok(value) -> f(value)
          Error(error) -> Error(error)
        }
      }
    fn foo() -> Result(Int, Nil) {
      let start = 10
      use a <- and_then(Ok(1))
      Ok(start + a)
    }",
    )
}
