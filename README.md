# Glimpse

Perhaps, a library for parsing and typechecking a gleam project. Wraps the AST
produced by [glance](https://hex.pm/packages/glance) with two pieces:

- Ability to represent and introspect a gleam program (multiple interdependent
  modules) as opposed to just one module.
- Typechecking both within and between modules.

This package is not filesystem aware. That means all modules need to be loaded
externally, but it does provide tooling to determine what dependencies need
to be loaded.

Docs: https://hexdocs.pm/glimpse/
Repo: https://github.com/dusty-phillips/glimpse

## Development

```sh
gleam test  # Run the tests
```

## Loading packages

The main entry point is `glimpse.load_package`. It accepts the name of the package
and a function that accepts the string name of a module and returns the contents
of the module.

```gleam
pub fn load_package(
  package_name: String,
  loader: fn(String) -> Result(String, a),
) -> Result(Package, error.GlimpseError(a))
```

The loader function will be called with the main module for the package (which
is always package_name) and for every module that is imported by that module
(recursively).

Here's an example from the [macabre](https://github.com/dusty-phillips/macabre)
gleam-to-python compiler:

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
by their dependencies and checks each in turn:

```gleam
pub fn package(
  package: glimpse.Package,
) -> Result(glimpse.Package, error.GlimpseError(a))
```

It returns the package with inferred types filled in. Lower-level entry points
live in `glimpse/typecheck` for checking individual modules, constants, custom
types, and functions.

The typechecker covers expressions, statements, patterns, annotations, imports
(including aliases and unqualified imports), module constants, custom types,
function signatures and bodies, `use` syntax, and case expressions. Generic
callables are instantiated at each call site, so polymorphic functions such as
`fn identity(x: a) -> a { x }` check correctly.

It is not yet a complete Gleam typechecker. Known gaps:

- Parametric custom types (`type Box(a)`) are not supported: `List`, `Result`,
  and `Option` are handled specially, but a user-defined type parameter in an
  annotation currently errors.
- Generic function inference is shallow: generic calls are checked for
  consistency at each call site, but the most general type is not inferred.

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
