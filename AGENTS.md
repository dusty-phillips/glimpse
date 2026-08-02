# AGENTS.md

Glimpse is a Gleam library providing package loading and typechecking for Gleam projects. It wraps the AST produced by the `glance` library to add:

1. **Package representation** — represent and introspect a complete Gleam program (multiple interdependent modules) rather than just individual modules
2. **Cross-module typechecking** — typecheck both within and between modules

The library is filesystem-agnostic: external module loading happens through a loader function.

## Commands

- `gleam test` — run all tests
- `gleam build` — build the project
- `gleam format` — format code; always run after completing a task

## Code style

- Never add comments that just restate the code. Docstrings are good; comments that say what the code obviously says should be avoided.

## Architecture

### Main types

- `glimpse.Package` — a complete package with a name and collection of modules
- `glimpse.Module` — wraps a `glance.Module` with additional metadata (name, dependencies)
- `glimpse/error.GlimpseError` — comprehensive error handling for load, parse, import, and typecheck errors

### Key modules

- `src/glimpse.gleam` — main entry point with `load_package()` and core types
- `src/glimpse/typecheck.gleam` — public typechecking API: `package()`, `module()`, `constant()`, `custom_type()`, `function()`
- `src/glimpse/internal/typecheck/` — internal implementation:
  - `types.gleam` — type system definitions, Environment management, and the type store used for unification, instantiation, and generalisation
  - `functions.gleam` — function signature and parameter handling, variant constructor types
  - `imports.gleam` — import resolution and module environment merging
  - `pattern.gleam` — pattern typechecking
- `src/glimpse/internal/typecheck.gleam` — expression, statement, call, and case typechecking
- `src/glimpse/internal/import_dependencies.gleam` — dependency sorting and circular dependency detection

### Typechecking flow

1. **Package-level**: `typecheck.package()` sorts dependencies and processes modules in order
2. **Module-level**: `typecheck.module()` processes imports, custom types, function signatures, then function bodies
3. **Function-level**: `typecheck.function()` handles parameters, type inference, and return type validation
4. **Expression-level**: generic callables are instantiated to fresh variables at each call site, unified against the arguments, and the result is generalised back to named type variables

### Environment system

An `Environment` type tracks: current module context, available definitions (functions, variables), custom types and their visibility, and import mappings / module environments. A transient `TypeStore` threads the state of inference variables created while unifying a single call; it is discarded once the call's return type has been resolved.

## Testing structure

- Tests use `gleeunit`.
- Main test files live in `test/`; typecheck tests are in `test/typecheck/` with helper utilities in `helpers.gleam`.
- Use `assert actual == expected` instead of `gleeunit.should_*` or `let assert` in unit tests. For example, to verify a Result containing a string, use `assert actual == Ok("hello world")`. This is available since gleam 1.11.

## Dependencies

- `gleam_stdlib` — standard library
- `glance` — Gleam AST parser that this library wraps
- `gleeunit` — testing framework (dev dependency)
- `pprint` — pretty printing for debugging (dev dependency)

## Debugging

Use `echo` syntax instead of print statements:

```gleam
echo some_value
```

Prints the value with file:line context to stderr.

## Current status

The typechecker covers every expression, statement, and pattern variant in the
glance AST, typechecks both within and between modules, and supports generics
(parametric custom types and polymorphic functions) through instantiation at
each call site. It is not yet available in public releases.
