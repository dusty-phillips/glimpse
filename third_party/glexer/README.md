# glexer (vendored)

glexer 2.5.0 vendored from hex, with one local patch:

- `lex_uppercase_name` accepts `_` in uppercase identifiers (real Gleam
  lexes `Foo_bar` as a single name; upstream glexer split it into
  `Foo` + `_bar`). See Bug 48.

Re-apply the patch to `src/glexer.gleam` if the dependency is refreshed.
