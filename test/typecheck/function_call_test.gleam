import glance
import gleam/list
import gleam/option
import glimpse/error
import typecheck/helpers

pub fn simple_nil_function_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn foo() -> Nil { Nil }
    fn bar() -> Nil { foo() } ",
    )

  assert list.length(module.module.functions) == 2
}

pub fn fully_typed_function_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", \"body\")
      Nil
    } ",
    )

  assert list.length(module.module.functions) == 2
}

pub fn fully_labelled_function_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn foo(first one: String, last two: String) -> String { \"Hello, \" <> one <> \" \" <> two }
    fn bar() -> Nil { foo(first: \"Some\", last: \"body\")
      Nil
    } ",
    )

  assert list.length(module.module.functions) == 2
}

pub fn partially_labelled_function_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn foo(first one: String, last two: String) -> String { \"Hello, \" <> one <> \" \" <> two }
    fn bar() -> Nil { foo(\"Body\", first: \"Some\")
      Nil
    } ",
    )

  assert list.length(module.module.functions) == 2
}

pub fn error_if_incorrect_args_test() {
  let actual =
    helpers.error_module_typecheck(
      "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", 1)
      Nil
    } ",
    )
  assert actual == error.InvalidArguments("(String, String)", "(String, Int)")
}

pub fn error_if_missing_args_test() {
  let actual =
    helpers.error_module_typecheck(
      "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", )
      Nil
    } ",
    )
  assert actual == error.InvalidArguments("(String, String)", "(String)")
}

pub fn error_if_extra_args_test() {
  let actual =
    helpers.error_module_typecheck(
      "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", \"Body\", \"else\")
      Nil
    } ",
    )
  assert actual
    == error.InvalidArguments("(String, String)", "(String, String, String)")
}

pub fn error_if_unknown_label_test() {
  let actual =
    helpers.error_module_typecheck(
      "fn foo(one first: String, two last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", xxx: \"Body\")
      Nil
    } ",
    )
  assert actual == error.InvalidArgumentLabel("(one, two)", "xxx")
}

pub fn error_if_label_unlabelled_args_test() {
  let actual =
    helpers.error_module_typecheck(
      "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(first: \"Some\", last: \"Body\")
      Nil
    } ",
    )
  assert actual == error.InvalidArgumentLabel("()", "first")
}

pub fn simple_nil_variant_call_test() {
  helpers.ok_module_typecheck(
    "pub type Foo {
        Foo
    }
    fn bar() -> Foo { Foo } ",
  )
}

pub fn multi_nil_variant_call_test() {
  assert helpers.error_module_typecheck(
      "pub type Foo {
        Foo
        Bar
    }
    fn bar() -> Foo { Foo } 
    fn bar() -> Foo { Bar } ",
    )
    == error.DuplicateDefinition("bar")
}

pub fn single_param_variant_call_test() {
  helpers.ok_module_typecheck(
    "pub type Foo {
        Foo(String)
    }
    fn bar() -> Foo { Foo(\"hello\") } 
  ",
  )
}

pub fn labelled_param_variant_call_test() {
  helpers.ok_module_typecheck(
    "pub type Foo {
        Foo(name: String)
    }
    fn bar() -> Foo { Foo(name: \"hello\") } 
  ",
  )
}

pub fn labelled_param_variant_optional_call_test() {
  helpers.ok_module_typecheck(
    "pub type Foo {
        Foo(name: String)
    }
    fn bar() -> Foo { Foo(\"hello\") } 
  ",
  )
}

pub fn unexpected_label_in_variant_call_test() {
  let actual =
    helpers.error_module_typecheck(
      "pub type Foo {
        Foo(name: String)
    }
    fn bar() -> Foo { Foo(wrong_label: \"hello\") } 
  ",
    )
  assert actual == error.InvalidArgumentLabel("(name)", "wrong_label")
}

pub fn incorrect_arity_in_variant_call_test() {
  let actual =
    helpers.error_module_typecheck(
      "pub type Foo {
        Foo(name: String)
    }
    fn bar() -> Foo { Foo(\"hello\", 2) } 
  ",
    )
  assert actual == error.InvalidArguments("(String)", "(String, Int)")
}

pub fn incorrect_type_in_variant_call_test() {
  let actual =
    helpers.error_module_typecheck(
      "pub type Foo {
        Foo(name: String)
    }
    fn bar() -> Foo { Foo(2) } 
  ",
    )
  assert actual == error.InvalidArguments("(String)", "(Int)")
}

pub fn shorthand_field_function_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn greet(name person: String) -> String { \"Hello, \" <> person }
    fn bar() -> String { 
      let name = \"World\"
      greet(name:)
    } ",
    )

  assert list.length(module.module.functions) == 2
}

pub fn shorthand_field_variant_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "pub type Person {
          Person(name: String, age: Int)
      }
      fn create_person() -> Person { 
        let name = \"Alice\"
        let age = 30
        Person(name:, age:)
      } ",
    )

  assert list.length(module.module.functions) == 1
}

pub fn shorthand_field_mixed_with_regular_test() {
  let actual =
    helpers.error_module_typecheck(
      "fn greet(first f: String, last l: String) -> String { \"Hello, \" <> f <> \" \" <> l }
    fn bar() -> String { 
      let first = \"John\"
      greet(first:, \"Doe\")
    } ",
    )
  assert actual == error.PositionalArgumentAfterLabelled
}

pub fn labelled_fields_ordered_after_positional_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn greet(first: String, last l: String) -> String { l }
    fn bar() -> String { 
      greet(\"John\", last: \"Doe\")
    } ",
    )
  assert list.length(module.module.functions) == 2
}

pub fn shorthand_field_error_if_variable_not_in_scope_test() {
  let actual =
    helpers.error_module_typecheck(
      "fn greet(name person: String) -> String { \"Hello, \" <> person }
    fn bar() -> String { 
      greet(name:)
    } ",
    )
  assert actual == error.InvalidName("name")
}

pub fn generic_identity_function_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn identity(x: a) -> a { x }
       fn use_identity() -> Int { identity(42) }",
    )

  assert list.length(module.module.functions) == 2
}

pub fn generic_function_shorthand_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn consume(value x: a) -> a { x }
       fn use_consume() -> Int {
         let value = 42
         consume(value:)
       }",
    )

  assert list.length(module.module.functions) == 2

  let assert [use_consume_def, _] = module.module.functions
  assert use_consume_def.definition.return
    == option.Some(
      glance.NamedType(glance.Span(61, 64), "Int", option.None, []),
    )
}

pub fn multiple_type_variables_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn first(x: a, y: b) -> a { x }
       fn use_first() -> Int { first(42, \"hello\") }",
    )

  assert list.length(module.module.functions) == 2

  let assert [use_first_def, _] = module.module.functions
  assert use_first_def.definition.return
    == option.Some(
      glance.NamedType(glance.Span(57, 60), "Int", option.None, []),
    )
}

pub fn mixed_generic_concrete_parameters_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn repeat(value: a, count: Int) -> a { value }
       fn use_repeat() -> String { repeat(\"hello\", 3) }",
    )

  assert list.length(module.module.functions) == 2

  let assert [use_repeat_def, _] = module.module.functions
  assert use_repeat_def.definition.return
    == option.Some(
      glance.NamedType(glance.Span(73, 79), "String", option.None, []),
    )
}

pub fn generic_function_wrong_arity_test() {
  let actual =
    helpers.error_module_typecheck(
      "fn identity(x: a) -> a { x }
     fn use_identity() -> Int { identity(42, \"extra\") }",
    )
  assert actual == error.InvalidArguments("(var_0)", "(Int, String)")
}

pub fn generic_constraints_from_complex_arguments_test() {
  // Calling a same-module generic function (whose return is still a
  // placeholder) with list/tuple/bit-string/call arguments exercises the
  // argument-named-vars traversal for each expression shape.
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn later(rest: List(Int), x: Int) -> Nil {
      let _ = consume([1, ..rest], [1, 2], #(1, 2), <<1:size(8)>>, pair(x, 0))
      Nil
    }
    fn consume(a: a, b: b, c: c, d: d, e: e) -> a {
      a
    }
    fn pair(x: Int, y: Int) -> #(Int, Int) {
      #(x, y)
    }",
    )

  assert list.length(module.module.functions) == 3
}
