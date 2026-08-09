import glance
import gleam/list
import gleam/option
import glimpse/target

fn external_function(target_name: String) -> glance.Definition(glance.Function) {
  let function =
    glance.Function(
      glance.Span(0, 0),
      "f",
      glance.Public,
      [],
      option.None,
      [],
    )
  glance.Definition(
    attributes: [
      glance.Attribute(
        "external",
        [glance.Variable(glance.Span(0, 0), target_name)],
      ),
    ],
    definition: function,
  )
}

pub fn has_external_for_matching_target_test() {
  assert target.has_external_for_target(target.Erlang, external_function("erlang"))
    == True
}

pub fn has_external_for_different_target_test() {
  assert target.has_external_for_target(target.Erlang, external_function("javascript"))
    == False
}

pub fn no_external_attributes_returns_false_test() {
  let definition =
    glance.Definition(
      attributes: [],
      definition: glance.Function(
        glance.Span(0, 0),
        "f",
        glance.Public,
        [],
        option.None,
        [],
      ),
    )
  assert target.has_external_for_target(target.Erlang, definition) == False
}
