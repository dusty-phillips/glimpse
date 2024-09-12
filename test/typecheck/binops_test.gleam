import glance
import gleam/option
import gleeunit/should
import glimpse/error
import typecheck/helpers

pub fn bool_and_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Bool { True && False }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Bool", option.None, [])))
}

pub fn bool_and_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Bool { 1.1 && False }")
  |> should.equal(error.InvalidBinOp("&&", "Float", "Bool", "two Bools"))
}

pub fn bool_and_right_test() {
  helpers.error_function_typecheck("fn foo() -> Bool { True && 1.0 }")
  |> should.equal(error.InvalidBinOp("&&", "Bool", "Float", "two Bools"))
}

pub fn bool_or_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Bool { True || False }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Bool", option.None, [])))
}

pub fn bool_or_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Bool { 1.1 || False }")
  |> should.equal(error.InvalidBinOp("||", "Float", "Bool", "two Bools"))
}

pub fn bool_or_right_test() {
  helpers.error_function_typecheck("fn foo() -> Bool { True || 1.0 }")
  |> should.equal(error.InvalidBinOp("||", "Bool", "Float", "two Bools"))
}

pub fn bool_eq_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Bool { True == False }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Bool", option.None, [])))
}

pub fn int_eq_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { 1 == 2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn int_eq_infer_return_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { 1 == 2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn eq_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Bool { 1.1 == False }")
  |> should.equal(error.InvalidBinOp("==", "Float", "Bool", "same type"))
}

pub fn eq_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Bool { True == 1.0 }")
  |> should.equal(error.InvalidBinOp("==", "Bool", "Float", "same type"))
}

pub fn int_neq_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { 1 != 2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn int_neq_infer_return_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() { 1 != 2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn neq_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Bool { 1.1 != False }")
  |> should.equal(error.InvalidBinOp("!=", "Float", "Bool", "same type"))
}

pub fn neq_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Bool { True != 1.0 }")
  |> should.equal(error.InvalidBinOp("!=", "Bool", "Float", "same type"))
}

pub fn int_less_than_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { 1 < 2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn int_less_than_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1.0 < 2 }")
  |> should.equal(error.InvalidBinOp("<", "Float", "Int", "two Ints"))
}

pub fn int_less_than_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1 < 2.0 }")
  |> should.equal(error.InvalidBinOp("<", "Int", "Float", "two Ints"))
}

pub fn float_less_than_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Float { 1.1 <. 2.2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Float", option.None, [])))
}

pub fn float_less_than_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1 <. 2.2 }")
  |> should.equal(error.InvalidBinOp("<.", "Int", "Float", "two Floats"))
}

pub fn float_less_than_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1.1 <. 2 }")
  |> should.equal(error.InvalidBinOp("<.", "Float", "Int", "two Floats"))
}

pub fn int_less_than_or_equal_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { 1 <= 2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn int_less_than_or_equal_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1.0 <= 2 }")
  |> should.equal(error.InvalidBinOp("<=", "Float", "Int", "two Ints"))
}

pub fn int_less_than_or_equal_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1 <= 2.0 }")
  |> should.equal(error.InvalidBinOp("<=", "Int", "Float", "two Ints"))
}

pub fn float_less_than_or_equal_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Float { 1.1 <=. 2.2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Float", option.None, [])))
}

pub fn float_less_than_or_equal_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1 <=. 2.2 }")
  |> should.equal(error.InvalidBinOp("<=.", "Int", "Float", "two Floats"))
}

pub fn float_less_than_or_equal_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1.1 <=. 2 }")
  |> should.equal(error.InvalidBinOp("<=.", "Float", "Int", "two Floats"))
}

pub fn int_greater_than_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { 1 > 2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn int_greater_than_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1.0 > 2 }")
  |> should.equal(error.InvalidBinOp(">", "Float", "Int", "two Ints"))
}

pub fn int_greater_than_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1 > 2.0 }")
  |> should.equal(error.InvalidBinOp(">", "Int", "Float", "two Ints"))
}

pub fn float_greater_than_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Float { 1.1 >. 2.2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Float", option.None, [])))
}

pub fn float_greater_than_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1 >. 2.2 }")
  |> should.equal(error.InvalidBinOp(">.", "Int", "Float", "two Floats"))
}

pub fn int_greater_than_or_equal_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { 1 >= 2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn int_greater_than_or_equal_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1.0 >= 2 }")
  |> should.equal(error.InvalidBinOp(">=", "Float", "Int", "two Ints"))
}

pub fn int_greater_than_or_equal_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1 >= 2.0 }")
  |> should.equal(error.InvalidBinOp(">=", "Int", "Float", "two Ints"))
}

pub fn float_greater_than_or_equal_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Float { 1.1 >=. 2.2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Float", option.None, [])))
}

pub fn float_greater_than_or_equal_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1 >=. 2.2 }")
  |> should.equal(error.InvalidBinOp(">=.", "Int", "Float", "two Floats"))
}

pub fn float_greater_than_or_equal_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1.1 >=. 2 }")
  |> should.equal(error.InvalidBinOp(">=.", "Float", "Int", "two Floats"))
}

pub fn float_greater_than_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1.1 >. 2 }")
  |> should.equal(error.InvalidBinOp(">.", "Float", "Int", "two Floats"))
}

pub fn int_add_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { 1 + 2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn int_add_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1.0 + 2 }")
  |> should.equal(error.InvalidBinOp("+", "Float", "Int", "two Ints"))
}

pub fn int_add_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1 + 2.0 }")
  |> should.equal(error.InvalidBinOp("+", "Int", "Float", "two Ints"))
}

pub fn float_add_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Float { 1.1 +. 2.2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Float", option.None, [])))
}

pub fn float_add_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1 +. 2.2 }")
  |> should.equal(error.InvalidBinOp("+.", "Int", "Float", "two Floats"))
}

pub fn float_add_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1.1 +. 2 }")
  |> should.equal(error.InvalidBinOp("+.", "Float", "Int", "two Floats"))
}

pub fn int_sub_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { 1 - 2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn int_sub_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1.0 - 2 }")
  |> should.equal(error.InvalidBinOp("-", "Float", "Int", "two Ints"))
}

pub fn int_sub_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1 - 2.0 }")
  |> should.equal(error.InvalidBinOp("-", "Int", "Float", "two Ints"))
}

pub fn float_sub_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Float { 1.1 -. 2.2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Float", option.None, [])))
}

pub fn float_sub_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1 -. 2.2 }")
  |> should.equal(error.InvalidBinOp("-.", "Int", "Float", "two Floats"))
}

pub fn float_sub_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1.1 -. 2 }")
  |> should.equal(error.InvalidBinOp("-.", "Float", "Int", "two Floats"))
}

pub fn int_mult_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { 1 * 2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn int_mult_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1.0 * 2 }")
  |> should.equal(error.InvalidBinOp("*", "Float", "Int", "two Ints"))
}

pub fn int_mult_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1 * 2.0 }")
  |> should.equal(error.InvalidBinOp("*", "Int", "Float", "two Ints"))
}

pub fn float_mult_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Float { 1.1 *. 2.2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Float", option.None, [])))
}

pub fn float_mult_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1 *. 2.2 }")
  |> should.equal(error.InvalidBinOp("*.", "Int", "Float", "two Floats"))
}

pub fn float_mult_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1.1 *. 2 }")
  |> should.equal(error.InvalidBinOp("*.", "Float", "Int", "two Floats"))
}

pub fn int_div_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { 1 / 2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn int_div_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1.0 / 2 }")
  |> should.equal(error.InvalidBinOp("/", "Float", "Int", "two Ints"))
}

pub fn int_div_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1 / 2.0 }")
  |> should.equal(error.InvalidBinOp("/", "Int", "Float", "two Ints"))
}

pub fn float_div_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Float { 1.1 /. 2.2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Float", option.None, [])))
}

pub fn float_div_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1 /. 2.2 }")
  |> should.equal(error.InvalidBinOp("/.", "Int", "Float", "two Floats"))
}

pub fn float_div_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Float { 1.1 /. 2 }")
  |> should.equal(error.InvalidBinOp("/.", "Float", "Int", "two Floats"))
}

pub fn int_remainder_test() {
  let function_out = helpers.ok_function_typecheck("fn foo() -> Int { 1 % 2 }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("Int", option.None, [])))
}

pub fn int_remainder_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1.0 % 2 }")
  |> should.equal(error.InvalidBinOp("%", "Float", "Int", "two Ints"))
}

pub fn int_remainder_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> Int { 1 % 2.0 }")
  |> should.equal(error.InvalidBinOp("%", "Int", "Float", "two Ints"))
}

pub fn string_concat_test() {
  let function_out =
    helpers.ok_function_typecheck("fn foo() -> String { \"a\" <> \"b\" }")

  function_out.return
  |> should.equal(option.Some(glance.NamedType("String", option.None, [])))
}

pub fn string_concat_invalid_left_test() {
  helpers.error_function_typecheck("fn foo() -> String { 1.0 <> \"b\" }")
  |> should.equal(error.InvalidBinOp("<>", "Float", "String", "two Strings"))
}

pub fn string_concat_invalid_right_test() {
  helpers.error_function_typecheck("fn foo() -> String { \"a\" <> 2.0 }")
  |> should.equal(error.InvalidBinOp("<>", "String", "Float", "two Strings"))
}
