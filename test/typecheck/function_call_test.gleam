import gleeunit/should
import glimpse/error
import typecheck/assertions
import typecheck/helpers

pub fn simple_nil_function_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn foo() -> Nil { Nil }
    fn bar() -> Nil { foo() } ",
    )

  assertions.should_have_list_length(module.module.functions, 2)
}

pub fn fully_typed_function_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", \"body\")
      Nil
    } ",
    )

  assertions.should_have_list_length(module.module.functions, 2)
}

pub fn fully_labelled_function_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn foo(first one: String, last two: String) -> String { \"Hello, \" <> one <> \" \" <> two }
    fn bar() -> Nil { foo(first: \"Some\", last: \"body\")
      Nil
    } ",
    )

  assertions.should_have_list_length(module.module.functions, 2)
}

pub fn partially_labelled_function_call_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "fn foo(first one: String, last two: String) -> String { \"Hello, \" <> one <> \" \" <> two }
    fn bar() -> Nil { foo(\"Body\", first: \"Some\")
      Nil
    } ",
    )

  assertions.should_have_list_length(module.module.functions, 2)
}

pub fn error_if_incorrect_args_test() {
  helpers.error_module_typecheck(
    "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", 1)
      Nil
    } ",
  )
  |> should.equal(error.InvalidArguments("(String, String)", "(String, Int)"))
}

pub fn error_if_missing_args_test() {
  helpers.error_module_typecheck(
    "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", )
      Nil
    } ",
  )
  |> should.equal(error.InvalidArguments("(String, String)", "(String)"))
}

pub fn error_if_extra_args_test() {
  helpers.error_module_typecheck(
    "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", \"Body\", \"else\")
      Nil
    } ",
  )
  |> should.equal(error.InvalidArguments(
    "(String, String)",
    "(String, String, String)",
  ))
}

pub fn error_if_unknown_label_test() {
  helpers.error_module_typecheck(
    "fn foo(one first: String, two last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(\"Some\", xxx: \"Body\")
      Nil
    } ",
  )
  |> should.equal(error.InvalidArgumentLabel("(one, two)", "xxx"))
}

pub fn error_if_label_unlabelled_args_test() {
  helpers.error_module_typecheck(
    "fn foo(first: String, last: String) -> String { \"Hello, \" <> first <> \" \" <> last }
    fn bar() -> Nil { foo(first: \"Some\", last: \"Body\")
      Nil
    } ",
  )
  |> should.equal(error.InvalidArgumentLabel("()", "first"))
}

pub fn simple_nil_variant_call_test() {
  helpers.ok_module_typecheck(
    "pub type Foo {
        Foo
    }
    fn bar() -> Foo { Foo() } ",
  )
}

pub fn multi_nil_variant_call_test() {
  helpers.ok_module_typecheck(
    "pub type Foo {
        Foo
        Bar
    }
    fn bar() -> Foo { Foo() } 
    fn bar() -> Foo { Bar() } ",
  )
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
  helpers.error_module_typecheck(
    "pub type Foo {
        Foo(name: String)
    }
    fn bar() -> Foo { Foo(wrong_label: \"hello\") } 
  ",
  )
  |> should.equal(error.InvalidArgumentLabel("(name)", "wrong_label"))
}

pub fn incorrect_arity_in_variant_call_test() {
  helpers.error_module_typecheck(
    "pub type Foo {
        Foo(name: String)
    }
    fn bar() -> Foo { Foo(\"hello\", 2) } 
  ",
  )
  |> should.equal(error.InvalidArguments("(String)", "(String, Int)"))
}

pub fn incorrect_type_in_variant_call_test() {
  helpers.error_module_typecheck(
    "pub type Foo {
        Foo(name: String)
    }
    fn bar() -> Foo { Foo(2) } 
  ",
  )
  |> should.equal(error.InvalidArguments("(String)", "(Int)"))
}
