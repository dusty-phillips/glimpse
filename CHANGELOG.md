# Changelog

## 1.0.0-rc.1

The typechecker is now feature-complete for the language and validated against
the official compiler with differential mutation testing across a wide range of
popular Gleam projects. Changes since 0.9.0:

### Typechecking
- Typecheck `@target` / `@external` annotations: definitions not active for the
  checked target are filtered out, and references to target-unsupported values
  are rejected, mirroring the real compiler.
- Reject calls to functions unsupported on the active target, and narrow
  dependency functions that reference target-restricted values.
- Validate external functions: type annotations on parameters and returns,
  no type holes, and correct `@external` attribute placement.
- Enforce bit-string rules: option validity, size variables, and negative or
  missing unit/size values.
- Handle rigid type variables correctly in function captures, recursive calls,
  and inferred parameter types.
- Defer exhaustiveness checking on unresolved case subjects, then re-check once
  the clause patterns pin the subject type.
- Reject private type leaks through public type aliases and public function
  signatures.
- Allow constants to reference opaque variant constructors by name.
- Fix positional constructor-pattern arguments to bind the next free field,
  matching the real compiler's field reordering.
- Reject duplicate attributes, misordered fields, unknown `@target` values,
  import cycles, and other grammar violations the real compiler catches at
  parse time.

### Testing
- Built a differential mutation harness (`dev/mutate_check`) that rewrites
  source modules and judges each mutant against the real `gleam check` and
  glimpse, reporting false negatives and false positives. Verdicts are
  persisted to durable files as they are judged, so interrupted runs can resume.
- Fixed every false negative and false positive found across sweeps of the
  standard library and 20+ popular Gleam projects (plinth, lily, lustre, mist,
  glisten, gleam_otp, sqlight, gossamer, glemplate, and more). One known,
  documented divergence remains in `jot`.

## 0.9.0

Package representation, cross-module typechecking, generics, and the mutation
testing harness.

Prior to 0.9.0: see the `0.0.1`–`0.0.3` releases.
