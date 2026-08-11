import glance
import gleam/dict
import glimpse
import glimpse/error
import glimpse/internal/typecheck/types
import glimpse/target
import glimpse/typecheck

/// A module with an erlang-only external, plus functions whose bodies call it,
/// standing in for a dependency package. The erlang-only external is only
/// usable on the erlang target.
fn other_package() -> String {
  "@external(erlang, \"erlonly\", \"new\")
  pub fn new() -> Int

  @external(erlang, \"erlonly\", \"id\")
  pub fn id(x: Int) -> Int

  pub fn wrapped() -> Int {
    new()
  }

  pub fn with_callback(callback: fn(Int) -> Int) -> Int {
    callback(new())
  }"
}

/// Typecheck `main_source` (the package's own module) against `other/package`
/// (a dependency): the dependency is checked without target-support enforcement
/// and its environment is passed to the root module, which is enforced.
fn root_typecheck(
  main_source: String,
  build_target: target.Target,
) -> error.TypeCheckResult(#(glimpse.Module, types.Environment)) {
  let assert Ok(dep_module) = glance.module(other_package())
  let assert Ok(#(_, dep_env)) =
    typecheck.module(
      glimpse.Module("other/package", dep_module, []),
      dict.new(),
      build_target,
      False,
    )
  let assert Ok(main_module) = glance.module(main_source)
  typecheck.module(
    glimpse.Module("main_module", main_module, ["other/package"]),
    dict.new() |> dict.insert("other/package", dep_env),
    build_target,
    True,
  )
}

/// Calling an erlang-only external directly from javascript-target code is
/// rejected at the call site, mirroring the real compiler.
pub fn calling_erlang_only_external_from_javascript_is_rejected_test() {
  let assert Error(err) =
    root_typecheck(
      "import other/package
      pub fn main() {
        package.new()
      }",
      target.Javascript,
    )
  assert err == error.UnsupportedTarget("new")
}

/// The same call from erlang-target code is fine.
pub fn calling_erlang_only_external_from_erlang_is_fine_test() {
  let assert Ok(_) =
    root_typecheck(
      "import other/package
      pub fn main() {
        package.new()
      }",
      target.Erlang,
    )
}

/// A function whose body calls an erlang-only external is itself only usable
/// on erlang, so calling it from javascript-target code is rejected (the
/// implementation support propagates through the call).
pub fn calling_function_whose_body_uses_erlang_only_external_is_rejected_test() {
  let assert Error(err) =
    root_typecheck(
      "import other/package
      pub fn main() {
        package.wrapped()
      }",
      target.Javascript,
    )
  assert err == error.UnsupportedTarget("wrapped")
}

/// The use-site check fires on the call target, so piping into a mismatched
/// function is rejected too.
pub fn piping_into_erlang_only_external_is_rejected_test() {
  let assert Error(err) =
    root_typecheck(
      "import other/package
      pub fn main() {
        1 |> package.id()
      }",
      target.Javascript,
    )
  assert err == error.UnsupportedTarget("id")
}

/// A `use` statement's function is called, so it is subject to the same check.
pub fn use_of_erlang_only_function_is_rejected_test() {
  let assert Error(err) =
    root_typecheck(
      "import other/package
      pub fn main() {
        use value <- package.with_callback(fn(x) { x })
        value
      }",
      target.Javascript,
    )
  assert err == error.UnsupportedTarget("with_callback")
}

/// A function capture referencing a mismatched external is rejected at the
/// capture site.
pub fn capturing_erlang_only_external_is_rejected_test() {
  let assert Error(err) =
    root_typecheck(
      "import other/package
      pub fn main() {
        package.id(_)
      }",
      target.Javascript,
    )
  assert err == error.UnsupportedTarget("id")
}

/// A dependency module whose own body calls an erlang-only external is not
/// flagged: target support is not enforced for dependencies, matching the real
/// compiler.
pub fn erlang_only_external_call_in_dependency_is_fine_test() {
  let assert Ok(module) = glance.module(other_package())
  let assert Ok(#(_, _)) =
    typecheck.module(
      glimpse.Module("other/package", module, []),
      dict.new(),
      target.Javascript,
      False,
    )
}

/// Not calling the mismatched function is always fine.
pub fn not_calling_erlang_only_external_is_fine_test() {
  let assert Ok(_) =
    root_typecheck(
      "import other/package
      pub fn main() {
        1
      }",
      target.Javascript,
    )
}
