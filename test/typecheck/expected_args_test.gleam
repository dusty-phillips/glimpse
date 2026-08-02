import gleam/list
import glimpse/error
import typecheck/helpers

pub fn anonymous_fn_arg_bound_to_expected_param_type_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "type Person { Person(name: String, age: Int) }
    fn make_person() -> Person { Person(\"A\", 1) }
    fn call(f: fn(Person) -> String) -> String { f(make_person()) }
    fn run() -> String {
      call(fn(p: Person) { p.name })
    }",
    )

  assert list.length(module.module.functions) == 3
}

pub fn pipe_with_lambda_inferred_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn apply(x: Int, f: fn(Int) -> Int) -> Int { f(x) }
    fn go() -> Int {
      5 |> apply(fn(x: Int) { x + 1 })
    }",
    )

  assert list.length(module.module.functions) == 2
}

pub fn use_with_callback_inferred_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn helper(x: Int, f: fn(Int) -> Int) -> Int { f(x) }
    fn main() -> Int {
      use y <- helper(5)
      y + 1
    }",
    )

  assert list.length(module.module.functions) == 2
}

pub fn error_wrong_type_in_lambda_arg_test() {
  let actual =
    helpers.error_module_typecheck(
      "fn apply(f: fn(Int) -> Int, x: Int) -> Int { f(x) }
    fn call_it() -> Int {
      apply(fn(s: Int) { s }, \"hi\")
    }",
    )

  assert actual
    == error.InvalidArguments(
      "(fn (Int) -> Int, Int)",
      "(fn (Int) -> Int, String)",
    )
}

pub fn error_extra_arity_test() {
  let actual =
    helpers.error_module_typecheck(
      "fn f(a: Int) -> Int { a }
    fn call_it() -> Int { f(1, 2) }",
    )

  assert actual == error.InvalidArguments("(Int)", "(Int, Int)")
}

pub fn error_field_access_on_nonexistent_field_test() {
  let actual =
    helpers.error_module_typecheck(
      "type Person { Person(name: String, age: Int) }
    fn make_person() -> Person { Person(\"A\", 1) }
    fn call(f: fn(Person) -> String) -> String { f(make_person()) }
    fn run() -> String {
      call(fn(p: Person) { p.bad })
    }",
    )

  assert actual == error.InvalidFieldAccess("main_module.Person", "bad")
}
