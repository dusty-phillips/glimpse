import glance
import gleam/list
import gleam/option

/// The build target that a package is being typechecked for. Definitions
/// annotated with `@target(erlang)`, `@target(javascript)`, or a custom target
/// name are only active for their target; definitions without a target
/// attribute apply to all.
///
/// `Erlang` and `Javascript` are the targets the real compiler builds for, and
/// `Named(name)` supports experimental backends with their own target names
/// (e.g. `@target(python)`).
pub type Target {
  Erlang
  Javascript
  Named(name: String)
}

/// Remove definitions whose `@target` attribute does not match the active
/// target. The real Gleam compiler performs this filtering before typechecking
/// so that e.g. the `@target(javascript)` variant of a type or function is not
/// seen when checking for erlang.
pub fn filter_for_target(
  module: glance.Module,
  target: Target,
) -> glance.Module {
  glance.Module(
    imports: list.filter(module.imports, fn(d) { is_active_for(target, d) }),
    custom_types: list.filter(module.custom_types, fn(d) {
      is_active_for(target, d)
    }),
    type_aliases: list.filter(module.type_aliases, fn(d) {
      is_active_for(target, d)
    }),
    constants: list.filter(module.constants, fn(d) { is_active_for(target, d) }),
    functions: list.filter(module.functions, fn(d) { is_active_for(target, d) }),
  )
}

fn is_active_for(target: Target, definition: glance.Definition(a)) -> Bool {
  case
    definition.attributes
    |> list.find(fn(attribute) { attribute.name == "target" })
  {
    // No target attribute: active on every target.
    Error(_) -> True
    Ok(attribute) ->
      case attribute.arguments {
        [glance.Variable(_, name)] -> name == target_name(target)
        _ -> True
      }
  }
}

fn target_name(target: Target) -> String {
  case target {
    Erlang -> "erlang"
    Javascript -> "javascript"
    Named(name) -> name
  }
}

/// Whether a function definition is usable on the given target: pure Gleam
/// functions and functions with a body run everywhere, while a body-less
/// external function runs only on the targets its `@external` attributes name.
/// A body-less function with no external at all has no implementation on any
/// target (the real compiler reports "Function without an implementation").
pub fn function_supported(
  target: Target,
  definition: glance.Definition(glance.Function),
) -> Bool {
  case external_attributes(definition) {
    [] -> function_has_braces_body(definition)
    _ ->
      case definition.definition.body {
        [] ->
          list.any(external_attributes(definition), fn(attribute) {
            external_usable_for_target(target, attribute)
          })
        _ -> True
      }
  }
}

/// Whether a function's external can serve as its implementation when checking
/// against `target`. An external for exactly `target` counts, and so does an
/// external for a target glimpse does not model: glimpse typechecks code for
/// runtimes the real compiler does not know, so such a function is treated as
/// having an implementation rather than rejected. This is the lenient variant
/// of `external_matches_target`, which stays strict because it decides whether
/// a function's Gleam body is skipped in favour of the external.
fn external_usable_for_target(
  target: Target,
  attribute: glance.Attribute,
) -> Bool {
  case attribute.arguments {
    [glance.Variable(_, name), ..] ->
      name == target_name(target) || name != "erlang" && name != "javascript"
    _ -> True
  }
}

/// Whether a function was written with a `{ ... }` body, as opposed to being a
/// body-less declaration. Glance represents both an empty `{}` body and no body
/// at all as an empty statement list, but the real compiler distinguishes them:
/// `pub fn f() -> Nil {}` is an implementation while `pub fn f() -> Nil` has no
/// implementation. The distinction is visible in the spans: a body extends the
/// function's span past its return annotation (or parameter list when there is
/// no return annotation).
fn function_has_braces_body(
  definition: glance.Definition(glance.Function),
) -> Bool {
  let function = definition.definition
  // A function with a return annotation but no body cannot be distinguished
  // from one whose body is empty by the body list alone (both are empty), so
  // the span is authoritative: a body extends the function's location past the
  // end of the return annotation. Without a return annotation there is no
  // anchor to compare against, so the function is treated as having a body:
  // the common `pub fn main() {}` must not be mistaken for the body-less
  // `pub fn main()`, and the genuinely body-less form without an annotation
  // is rare enough to accept.
  case function.return {
    option.Some(return_type) ->
      function.location.end > type_span_end(return_type)
    option.None -> True
  }
}

fn type_span_end(type_: glance.Type) -> Int {
  case type_ {
    glance.NamedType(location, _, _, _) -> location.end
    glance.TupleType(location, _) -> location.end
    glance.FunctionType(location, _, _) -> location.end
    glance.VariableType(location, _) -> location.end
    glance.HoleType(location, _) -> location.end
  }
}

fn external_matches_target(
  target: Target,
  attribute: glance.Attribute,
) -> Bool {
  case attribute.arguments {
    [glance.Variable(_, name), ..] -> name == target_name(target)
    _ -> True
  }
}

/// Whether a function's `@external` attributes include one for the given
/// target. A function with such an external uses the external implementation
/// on this target and its Gleam body is not checked; a function whose
/// externals are for other targets uses its body instead.
pub fn has_external_for_target(
  target: Target,
  definition: glance.Definition(glance.Function),
) -> Bool {
  list.any(external_attributes(definition), fn(attribute) {
    external_matches_target(target, attribute)
  })
}

fn external_attributes(
  definition: glance.Definition(glance.Function),
) -> List(glance.Attribute) {
  list.filter(definition.attributes, fn(attribute) {
    attribute.name == "external"
  })
}
