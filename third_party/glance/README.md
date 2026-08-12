# glance (vendored)

glance 7.0.0 vendored from hex, with one local patch:

- `type_definition` rejects `opaque` on the type-alias form
  (`pub opaque type X = ...` is a parse error in real Gleam; upstream
  glance silently dropped the opaque flag for aliases). See the opacity bug.

Re-apply the patch to `src/glance.gleam` if the dependency is refreshed.
