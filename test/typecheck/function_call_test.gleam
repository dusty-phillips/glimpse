import gleam/list
import gleeunit/should
import glimpse/error
import typecheck/helpers

pub fn simple_nil_function_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn foo() -> Nil { Nil }
    fn bar() -> Nil { foo() } ",
    )

  module.module.functions
  |> list.length
  |> should.equal(2)
}

pub fn fully_typed_function_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", \"body\")
      Nil
    } ",
    )

  module.module.functions
  |> list.length
  |> should.equal(2)
}

pub fn error_if_incorrect_args_test() {
  helpers.error_module_typecheck(
    "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", 1)
      Nil
    } ",
  )
  |> should.equal(error.InvalidArguments(
    "fn (String, String) -> String",
    "(String, Int)",
  ))
}

pub fn error_if_missing_args_test() {
  helpers.error_module_typecheck(
    "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", )
      Nil
    } ",
  )
  |> should.equal(error.InvalidArguments(
    "fn (String, String) -> String",
    "(String)",
  ))
}

pub fn error_if_extra_args_test() {
  helpers.error_module_typecheck(
    "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", \"Body\", \"else\")
      Nil
    } ",
  )
  |> should.equal(error.InvalidArguments(
    "fn (String, String) -> String",
    "(String, String, String)",
  ))
}
