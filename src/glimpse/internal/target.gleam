import glance
import gleam/list

/// The build target that a package is being typechecked for. Definitions
/// annotated with `@target(erlang)` or `@target(javascript)` are only active
/// for their target; definitions without a target attribute apply to all.
pub type Target {
  Erlang
  Javascript
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
  }
}
