# glance (vendored)

glance 7.0.0 vendored from hex, with one local patch:

- `type_definition` rejects `opaque` on the type-alias form
  (`pub opaque type X = ...` is a parse error in real Gleam; upstream
  glance silently dropped the opaque flag for aliases). See the opacity bug.

Re-apply the patch to `src/glance.gleam` if the dependency is refreshed.

- `case_` parses a body-less `case subject` (no `{ ... }`) as a case with no
  clauses: real Gleam parses this shape and only reports "Missing case body"
  during analysis, which never runs for target-filtered definitions.

- A trailing attribute with no following definition (e.g. `@external(...)`
  at end of file) is rejected with `UnexpectedAttributeEnd`; real Gleam
  reports "I was expecting a function definition after this".
- An unlabelled function parameter after a labelled one is rejected with
  `UnlabelledAfterLabelled`; real Gleam reports "Unlabelled argument after
  labelled argument" for the same shape.
- `Function` gains a `has_braces_body: Bool` field so an empty `{}` body is
  distinguishable from a bodyless declaration (real Gleam accepts `{}` as an
  implementation for any return annotation).
- The list parser rejects a doubled comma (`[1, , ]`); real Gleam reports a
  parse error for the empty element.
