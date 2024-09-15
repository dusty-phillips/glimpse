import gleam/dict
import gleeunit/should
import glimpse/internal/typecheck/types
import glimpse/internal/typecheck/variants
import pprint
import typecheck/helpers

pub fn simple_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor(name: String)
  }"
    |> helpers.ok_custom_type

  env.custom_types
  |> dict.size
  |> should.equal(1)

  env.constructors
  |> dict.size
  |> should.equal(1)

  let constructor =
    env.constructors
    |> dict.get("MyTypeConstructor")
    |> should.be_ok

  constructor.name
  |> should.equal("MyTypeConstructor")

  constructor.custom_type
  |> should.equal("MyType")

  constructor.fields
  |> should.equal([variants.NamedField("name", types.StringType)])
}

pub fn positional_variant_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor(String)
  }"
    |> helpers.ok_custom_type

  env.custom_types
  |> dict.size
  |> should.equal(1)

  env.constructors
  |> dict.size
  |> should.equal(1)

  let constructor =
    env.constructors
    |> dict.get("MyTypeConstructor")
    |> should.be_ok

  constructor.name
  |> should.equal("MyTypeConstructor")

  constructor.custom_type
  |> should.equal("MyType")

  constructor.fields
  |> should.equal([variants.PositionField(types.StringType)])
}

pub fn multi_variant_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor(name: String)
    NumberConstructor(number: Int)
  }"
    |> helpers.ok_custom_type

  env.custom_types
  |> dict.size
  |> should.equal(1)

  env.constructors
  |> dict.size
  |> should.equal(2)

  let constructor1 =
    env.constructors
    |> dict.get("MyTypeConstructor")
    |> should.be_ok
  constructor1.name
  |> should.equal("MyTypeConstructor")
  constructor1.custom_type
  |> should.equal("MyType")
  constructor1.fields
  |> should.equal([variants.NamedField("name", types.StringType)])

  let constructor2 =
    env.constructors
    |> dict.get("NumberConstructor")
    |> should.be_ok
  constructor2.name
  |> should.equal("NumberConstructor")
  constructor2.custom_type
  |> should.equal("MyType")
  constructor2.fields
  |> should.equal([variants.NamedField("number", types.IntType)])
}

pub fn recursive_custom_type_test() {
  let env =
    "type MyType {
    MyTypeConstructor(name: String)
    RecursiveConstructor(next: MyType)
  }"
    |> helpers.ok_custom_type

  pprint.debug(env)

  env.custom_types
  |> dict.size
  |> should.equal(1)

  env.constructors
  |> dict.size
  |> should.equal(2)

  let constructor1 =
    env.constructors
    |> dict.get("MyTypeConstructor")
    |> should.be_ok
  constructor1.name
  |> should.equal("MyTypeConstructor")
  constructor1.custom_type
  |> should.equal("MyType")
  constructor1.fields
  |> should.equal([variants.NamedField("name", types.StringType)])

  let constructor2 =
    env.constructors
    |> dict.get("RecursiveConstructor")
    |> should.be_ok
  constructor2.name
  |> should.equal("RecursiveConstructor")
  constructor2.custom_type
  |> should.equal("MyType")
  constructor2.fields
  |> should.equal([variants.NamedField("next", types.CustomType("MyType"))])
}