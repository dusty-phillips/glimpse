# Glimpse

A library for parsing, loading, and typechecking a complete Gleam project. It
wraps the AST produced by [glance](https://hex.pm/packages/glance) with:

- a representation of a whole program — multiple interdependent modules — rather
  than a single module.
- typechecking both within and between modules.

Glimpse is not filesystem-aware: modules are loaded externally through a loader
function. It mirrors the official Gleam compiler's behavior closely; it has been
validated with differential mutation testing against the real compiler across a
wide range of popular Gleam projects.

Glimpse 1.0.0-rc.1 is available on [hex.pm](https://hex.pm/packages/glimpse).

Docs: https://hexdocs.pm/glimpse/
Repo: https://github.com/dusty-phillips/glimpse

## Install

```sh
gleam add glimpse
```

## Quickstart

Load a package, then typecheck it for the Erlang target:

```gleam
import gleam/io
import gleam/result
import glimpse
import glimpse/target
import glimpse/typecheck

fn load_module(module_name: String) -> Result(String, Nil) {
  // read the module contents from the filesystem here
  Ok("<contents of " <> module_name <> ".gleam>")
}

pub fn main() {
  let package =
    glimpse.load_package("my_package", load_module)
    |> result.map(typecheck.package(_, target.Erlang))

  case package {
    Ok(_) -> io.println("typechecked ok")
    Error(_) -> io.println("typecheck failed")
  }
}
```

The package is loaded with a loader function and returned with inferred types
filled in; you can then iterate the modules and inspect the resolved AST.

## Loading packages

`glimpse.load_package` accepts the package name and a function that takes a
module name and returns that module's contents. The loader is called with the
main module (the package name) and, recursively, for every module that is
imported:

```gleam
pub fn load_glimpse_package(
  project: project.Project,
) -> Result(glimpse.Package, errors.Error) {
  glimpse.load_package(project.name, fn(module_name) {
    let path =
      filepath.join(project.build_src_dir(project), module_name <> ".gleam")
    filesystem.read(path)
  })
  |> result.map_error(fn(error) {
    case error {
      glimpse.LoadError(error) -> error
      glimpse.ParseError(glance_error, name, content) ->
        errors.GlanceParseError(glance_error, name, content)
    }
  })
}
```

## Typechecking

Glimpse is a full Hindley-Milner type checker with exhaustiveness checking,
across module boundaries. `typecheck.package` sorts the modules by their
dependencies and checks each in turn, returning the package with inferred types
filled in:

```gleam
pub fn package(
  package: glimpse.Package,
  target: target.Target,
) -> Result(glimpse.Package, error.GlimpseError(a))
```

### Targets

`@target(erlang)` / `@target(javascript)` definitions that are not active for
the target being checked are filtered out before typechecking, mirroring the
real compiler. Pass `target.Erlang` or `target.Javascript`. Experimental
backends can use `target.Named(name)` so a `@target(python)` definition is
active when checking for `target.Named("python")`; the same matching applies to
`@external(...)` annotations.

### Lower-level entry points

`glimpse/typecheck` also checks a single module, constant, or function against
an existing type environment:

- `module(glimpse_module, module_envs, target)` — typechecks one module; any
  modules it imports must already have been checked.
- `constant(environment, constant)` — typechecks a module constant.
- `function(environment, function)` — typechecks a function body.

### Errors

Functions return a `Result`, with errors reported as `glimpse/error`'s
`GlimpseError`:

- `LoadError` — a module failed to load.
- `ParseError` — a module failed to parse.
- `ImportError` — a missing import, a circular dependency, or a source module
  importing a development dependency.
- `TypeCheckError` — an error in the code being checked, such as a type
  mismatch, unknown custom type, or invalid argument.

Because Glimpse is not filesystem-aware, it cannot discover dev-only modules on
its own. Set `Package.dev_dependencies` to those module names after loading so
that a source module importing one is reported as an `ImportError`, mirroring
the real compiler's `src`/`dev` split.

## Development

The repo ships two dev tools in `dev/`. Pass their arguments after a `--`
separator:

```s
gleam test                                # Run the unit tests
gleam run -m dev_check                    # Typecheck glimpse against itself
gleam run -m dev_check -- --typecheck <root>
gleam run -m mutate_check -- --root <root> --src <src_rel> [--jobs <n>] [--kind <kind>] [--count] [--both] [--resume]
```

- `dev_check` typechecks a project checkout with its `build/packages/`
  dependencies, or (with no arguments) glimpse against itself.
- `mutate_check` is a differential mutation harness: it rewrites small pieces of
  a source module and judges each mutant against the real `gleam check` (ground
  truth) and glimpse, reporting false negatives (glimpse accepts what the real
  compiler rejects) and false positives. Verdicts are appended to durable files
  under `/tmp/mutcheck/` as they are judged, so interrupted runs can continue
  with `--resume`. Do not run two sweeps against the same root concurrently;
  different roots in parallel are fine.
