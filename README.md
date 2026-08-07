# Glimpse

A library for parsing, loading, and typechecking a Gleam project. It wraps the
AST produced by [glance](https://hex.pm/packages/glance) with two pieces:

- The ability to represent and introspect a Gleam program (multiple
  interdependent modules) as opposed to just one module.
- Typechecking both within and between modules.

Glimpse is not filesystem aware: all modules are loaded externally through a
loader function. It provides tooling to determine which dependencies need to be
loaded, and it typechecks across module boundaries.

It is not yet a complete Gleam typechecker, but it covers the common parts of
the language so that folks targeting different languages from Gleam can focus
on codegen.

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

The package is loaded with a loader function (see below) and returned with
inferred types filled in. You can then iterate the modules and inspect the
resolved AST.

## Loading packages

The main entry point is `glimpse.load_package`. It accepts the name of the
package and a function that accepts the string name of a module and returns the
contents of the module. The loader is called with the main module for the
package (which is always the package name) and, recursively, for every module
that is imported.

Here's a condensed example from [macabre](https://github.com/dusty-phillips/macabre),
a Gleam-to-Python compiler:

```gleam
fn load_glimpse_package(
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

Glimpse can typecheck a loaded package, both within and between modules. The
entry point you'll usually want is `typecheck.package`, which sorts the modules
by their dependencies and checks each in turn. It takes the target the package
is being built for, and returns the package with inferred types filled in:

```gleam
pub fn package(
  package: glimpse.Package,
  target: target.Target,
) -> Result(glimpse.Package, error.GlimpseError(a))
```

### Targets

Glimpse handles `@target(erlang)` / `@target(javascript)` annotations: definitions
that are not active for the target being checked are filtered out before
typechecking, mirroring the real compiler. Pass `target.Erlang` or
`target.Javascript` to `typecheck.package`.

Experimental backends targeting another language can use `target.Named(name)`
to check with their own target, so a `@target(python)` definition is active
when checking for `target.Named("python")` and filtered out otherwise. The same
matching applies to `@external(...)` annotations.

### Lower-level entry points

`glimpse/typecheck` also exposes functions for checking a single module,
constant, or function against an existing type environment:

- `module(glimpse_module, module_envs, target)` — typechecks one module; any
  modules it imports must already have been checked.
- `constant(environment, constant)` — typechecks a module constant.
- `function(environment, function)` — typechecks a function body against the
  environment.

### Errors

Functions return a `Result`, with errors reported as `glimpse/error`'s
`GlimpseError` type. Its variants cover the whole pipeline:

- `LoadError` — a module failed to load.
- `ParseError` — a module failed to parse.
- `ImportError` — a missing import, a circular dependency, or a source module
  importing a development dependency.
- `TypeCheckError` — an error in the code being checked, such as a type
  mismatch, unknown custom type, or invalid argument.

Because Glimpse is not filesystem-aware, it can't discover which modules are
dev-only on its own. Set `Package.dev_dependencies` to the names of those
modules after loading so that a source module importing one is reported as an
`ImportError`, mirroring the real compiler's `src`/`dev` split.

## Future Ideas

My vision for the project is that it handles the common parts of gleam
compilation so that folks wanting to target different languages from gleam can
focus on the codegen part.

### Desugaring

I'd like to add some desugaring so that the output of glimpse is actually a
simpler AST than the glance AST representing the full gleam language. This
would reduce the footprint that compiler implementers need to cover while still
targeting the entire language.

A couple ideas include:

- Desugar use statements to their function call syntax (already implemented in
  macabre and just needs to be ported to this package)
- Translate labelled fields to direct calls
- ??? suggestions welcome

If I tackle this, it will probably happen _before_ type checking and inference
so the typechecker also doesnt have to cover the entirety of glance.

### Token positions

The glance library does not maintain token positions with AST nodes. It does
record the locations of parse errors, but that doesn't help with locating
errors further up the chain. E.g. when there is an error with typechecking,
there is currently no way to communicate to the user where the error occurred.

Solving this requires modifications to, a rewrite of, or a fork of the glance
library. I'm not willing to tackle that anytime soon, but it is a prerequisite
for the vision for this project.

## Development

```sh
gleam test  # Run the tests
```
