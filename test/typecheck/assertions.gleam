import gleam/dict
import gleam/list
import gleeunit/should
import glimpse/internal/typecheck/environment.{type Environment}
import glimpse/internal/typecheck/types.{type Type}

pub fn should_have_dict_size(dict: dict.Dict(a, b), size: Int) {
  dict |> dict.size |> should.equal(size)
}

pub fn should_have_list_length(list: List(a), size: Int) {
  list |> list.length |> should.equal(size)
}

pub fn should_have_type(env: Environment, name: String) {
  env.custom_types
  |> dict.get(name)
  |> should.be_ok
  |> should.equal(types.CustomType(name))
}

pub fn should_be_callable(
  env: Environment,
  definition_name: String,
  params: List(Type),
  position_labels: List(#(String, Int)),
  return: Type,
) -> Nil {
  env.definitions
  |> dict.get(definition_name)
  |> should.be_ok
  |> should.equal(types.CallableType(
    params,
    dict.from_list(position_labels),
    return,
  ))
}