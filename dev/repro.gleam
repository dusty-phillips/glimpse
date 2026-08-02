import glance
import gleam/io
import gleam/list
import gleam/string

pub fn main() {
  let assert Ok(module) = glance.module("fn f() -> Nil {\n  token.DotDot\n}")
  let assert Ok(func_def) = list.first(module.functions)
  let assert Ok(statement) = list.first(func_def.definition.body)
  let assert glance.Expression(expr) = statement
  io.println(string.inspect(expr))
}
