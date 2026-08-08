# Glimpse

A library for parsing, loading, and typechecking a Gleam project. It wraps the
AST produced by [glance](https://hex.pm/packages/glance) with two pieces:

- The ability to represent and introspect a Gleam program (multiple
  interdependent modules) as opposed to just one module.
- Typechecking both within and between modules.

Glimpse is not filesystem aware: all modules are loaded externally through a
loader function. It provides tooling to determine which dependencies need to be
loaded, and it typechecks across module boundaries.

It is intended to be feature complete for the entire language and I believe
I have achieved that. I've done extensive mutation testing as well as
typechecking various popular gleam projects.

Glimpse 0.9.0 is available on [hex.pm](https://hex.pm/packages/glimpse).

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

Glimpse can typecheck a loaded package, both within and between modules. It is a
full Hindley-Milner type checking implementation with exhaustiveness checking.

The entry point you'll usually want is `typecheck.package`, which sorts the
modules by their dependencies and checks each in turn. It takes the target the
package is being built for, and returns the package with inferred types filled
in:

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

Unlike the official Gleam compiler, experimental backends targeting another
language can use `target.Named(name)` to check with their own target, so
a `@target(python)` definition is active when checking for
`target.Named("python")` and filtered out otherwise. The same matching applies
to `@external(...)` annotations.

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

## Development

Two standalone dev tools live in `dev/`. Pass their arguments after a `--`
separator:

```s
gleam test                                # Run the unit tests
gleam run -m dev_check                    # Typecheck glimpse itself
gleam run -m dev_check -- --typecheck <root>
gleam run -m mutate_check -- --root <root> --src <src_rel> [--jobs <n>] [--kind <kind>] [--count]
```

### dev_check

`dev_check` with no arguments typechecks glimpse against itself: its own `src/`
and `dev/` modules plus the cached dependencies in `build/packages/`. A quick
smoke test that the typechecker still accepts its own code after a change.

Passing `--typecheck <root>` typechecks an external Gleam project checkout
instead. `<root>` must be a project root with its dependencies already cached
(run `gleam build` first): the checkout's `src/` modules are loaded under their
real names and its `build/packages/` cache provides the transitive
dependencies. The target is read from the project's `gleam.toml`, defaulting to
Erlang.

The typechecking core lives in the exported `run_typecheck` function, which
prints nothing; `mutate_check` calls it in-process for each mutant rather than
booting a fresh `dev_check` subprocess each time.

### mutate_check

`mutate_check` is a differential mutation harness for the typechecker. It takes
a single source module, generates many mutants by rewriting small pieces of it,
and judges each against the real compiler:

1. The real `gleam check` runs in the project checkout. If it rejects the
   mutant (non-zero exit), that is ground truth: the mutant has a genuine error
   that glimpse must also catch.
2. glimpse's `dev_check` runs against the same checkout. If glimpse *accepts* a
   mutant the real compiler rejected, that is a **false negative** bug in
   glimpse.

The official compiler is always ground truth, so any mutation that turns out to
be valid code is simply not counted — which makes it safe to over-generate
mutants. Mutants come from many *kinds*, each aimed at a different part of the
typechecker: signature type swaps, boolean literal flips, binary operators,
labelled arguments and record fields, tuple indexes, case patterns,
`Ok`/`Error` variants, bit-string options, imports, `use` expressions, pipes,
guards, and more.

Each mutant runs two subprocess compiles, which dominate the runtime, so the
harness spawns a worker pool (`--jobs <n>`, default 16). Each worker checks
against its own private copy of the project (`<root>.w<i>`), so the compiles
truly run concurrently and the original checkout is left untouched. The worker
copies are keyed only by the root path, so two concurrent invocations against
the *same* root would overwrite each other's files — run sweeps sequentially,
one root at a time.

Flags:

- `--root <root>` — the project checkout to mutate (required); must have its
  dependencies cached.
- `--src <src_rel>` — the source module to mutate, relative to `root`
  (required), e.g. `src/foo.gleam`.
- `--jobs <n>` — worker parallelism (default 16).
- `--kind <kind>` — only run one mutant kind, e.g. `type` or `use`.
- `--count` — print how many mutants each kind would generate, then exit
  without running any checks.

The final line reports `N/M FALSE NEGATIVES in <src>`, and the offending
mutants (description plus rewritten source) are appended to
`/tmp/mutcheck/falsenegs.txt` for inspection.


## Implementation notes

The initial typechecker was handcoded. I used AI for a few commits in the
sonnet 3 days and it absolutely massacred it. I lost time/interest in
typechecking and didn't think I'd ever finish it so I threw deepseek at it for
a few days and it "seems to be working."
