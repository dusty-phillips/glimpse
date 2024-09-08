# Glimpse

Perhaps, a library for parsing and typechecking a gleam project. Wraps the AST
produced by [glance](https://hex.pm/packages/glance) with two pieces:

- Ability to represent and introspect a gleam program (multiple interdependent
  modules) as opposed to just one module.
- Typechecking both within and between modules.

Currently only focused on the first bit!

This package is not filesystem aware. That means all modules need to be loaded
externally, but it does provide tooling to determine what dependencies need
to be loaded.

## Development

```sh
gleam test  # Run the tests
```
