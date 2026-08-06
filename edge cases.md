# Edge cases in the official Gleam compiler's typechecker that are broken in this repo

This document records concrete edge cases taken from the official Gleam compiler's
typechecker unit tests (`compiler-core/src/type_/tests/`) that are **broken** in
`glimpse`'s typechecker as of `main@4f08a22`.

For each finding I list:
- the official compiler's unit-test name (file it lives in),
- a minimal Gleam snippet that reproduces it,
- the **official** verdict (verified with `gleam check`, gleam 1.18.0) and
- what **glimpse** produces instead (verified by driving the public
  `glimpse.typecheck.module` API, Erlang target).

Each entry states whether glimpse incorrectly *accepts* bad code (a soundness
hole) or incorrectly *rejects* good code (a false positive). Most are the former.

Verification note: `glimpse` was queried via `typecheck.module(load_module(module,
"main_module"), dict.new(), target.Erlang)`; "glimpse: OK" means it accepted the
module, a specific error name means it rejected with that `error.TypeCheckError`
variant.

---

## 1. `echo` — wrong type and unvalidated value expression

Glimpse treats `echo` as returning `Nil` and does **not** typecheck the echoed
expression (only the optional message). The official compiler gives `echo`
**the type of the printed expression** and requires the expression itself to
typecheck.

### 1.1 Echoed value is never typechecked
Official test: `echo.rs` (echo value is a normal expression).

```gleam
pub fn main() { echo undefined }
```

- Official: **error** — `Undefined variable: undefined`.
- glimpse: **OK** — accepts a reference to an undefined variable.

### 1.2 Echo has the wrong result type
Official test: `echo.rs::echo_has_same_type_as_printed_expression`.

```gleam
pub fn main() -> Int { echo 1 }
```

- Official: **OK** (`fn() -> Int`).
- glimpse: **InvalidReturnType** (`Nil` where `Int` expected). glimpse claims
  the function returns `Nil`.

### 1.3 Echo breaks pipelines
Official test: `echo.rs::echo_in_pipeline_acts_as_the_identity_function`.

```gleam
pub fn main() {
  [1, 2, 3]
  |> echo
}
```

- Official: **OK** (`fn() -> List(Int)`).
- glimpse: **NotCallable** — because `echo` is classed as a non-function value
  rather than an identity function.

**Root cause:** `src/glimpse/internal/typecheck.gleam:642-654` returns
`NilType`
for `Echo` and discards `_expression`. The official compiler both checks the
inner expression and threads its type through.

---

## 2. `case` exhaustiveness is not checked

glimpse type-checks each clause but performs **no exhaustiveness analysis**, so
`case` expressions that are missing valid patterns are accepted.

### 2.1 Missing variant of a `Bool`
Official test: `exhaustiveness.rs` (inexhaustive Bool).

```gleam
pub fn main(x: Bool) { case x { True -> 1 } }
```

- Official: **error: Inexhaustive patterns** (missing `False`).
- glimpse: **OK**.

### 2.2 Missing variant of a custom type
Official test: `exhaustiveness.rs` (inexhaustive custom type).

```gleam
pub type Type { One Two }
pub fn main(x) { case x { One -> 1 } }
```

- Official: **error: Inexhaustive patterns** (missing `Two`).
- glimpse: **OK**.

### 2.3 Empty `case`
Official test: `exhaustiveness.rs` (empty case on Bool and on a 3-variant type).

```gleam
pub fn main(b: Bool) { case b {} }
```

- Official: **error: Inexhaustive patterns** (missing `True`, `False`).
- glimpse: not parseable — the `glance` parser rejects an empty clause list
  (`UnexpectedToken(RightBrace)`), so the module fails at parse stage. The
  typechecker's exhaustiveness engine would report it if the AST were
  constructible.

Related missing behaviour now fixed (same root cause as §2): `let` bindings
with a refutable pattern (`let True = b` — now **InexhaustivePattern**), and
guarded clauses that cannot guarantee coverage (`case b { True if c -> 1
False -> 2 }` — now **InexhaustivePattern**; guarded clauses are excluded from
the coverage matrix).

---

## 3. Bit-string segment typing is largely unvalidated

glimpse discards the resulting segment type/options in value bit strings and
only partially handles pattern segment discriminators; sizes and conflicting
options are never checked.

### 3.1 Unknown size expression is never typechecked
Official test: `errors.rs::bit_arrays` (size must be Int, here it is `String`).

```gleam
fn x() { "test" }
pub fn main() { let a = <<1:size(x())>> a }
```

- Official: **error: Type mismatch** (effect "size(...) must be Int").
- glimpse: **OK**.

### 3.2 Conflicting segment options accepted
Official test: `errors.rs::bit_array_segment_size` etc. (`<<1:8-size(5)>>`,
`<<1:size(2)-size(8)>>`, `<<1:unit(2)-unit(5)>>`, signed/endianness clashes).

```gleam
pub fn main() { let x = <<1:8-size(5)>> x }
```

- Official: **error: Invalid bit array segment** (conflicting sizes).
- glimpse: **OK**.

### 3.3 Negative / zero literal size accepted
Official test: `errors.rs::negative_size_pattern`, `zero_size_pattern`:

```gleam
pub fn main() { let assert <<1:size(-1)>> = <<>> 1 }
```

- Official: **error: Invalid bit array segment** (size must be positive).
- glimpse: **OK**.

### 3.4 Double variable assignment in a bit pattern
Official test: `errors.rs::double_assignment_in_bit_array`:

```gleam
pub fn main() { let assert <<a as b>> = <<>> a }
```

- Official: **error: Double variable assignment**.
- glimpse: **OK** (the `as` alias is not checked for re-binding).

**Root cause:** in value bit-string expressions the segment type is computed and
then discarded (`typecheck.gleam` expression `BitString` arm); pattern segments
(`pattern.gleam::bit_string_segment_type`) do not validate size/`unit`
signedness/endianness on a segment type any recognized discriminator.

---

## 4. Record update (`..`) validation gaps

### 4.1 Updating a multi-variant value is accepted
glimpse reports **OK** whereas the official compiler rejects updating a value
whose variant is open, and rejects cross-variant updates.

```gleam
pub type Wibble {
  Wibble(wibble: Int, wubble: Bool)
  Wobble(wobble: Int, wubble: Bool)
}
pub fn wibble(value: Wibble) { Wibble(..value, wubble: True) }
```

- Official: **error: Unsafe record update**.
- glimpse: **OK**.

### 4.2 Cross-variant update (same field shape) accepted
Official test: `errors.rs::record_update_compatible_fields_wrong_variant`:

```gleam
pub type Wibble {
  A(a: Int, b: Int)
  B(a: Int, b: Int)
}
pub fn b_to_a(value: Wibble) {
  case value {
    A(..) -> value
    B(..) as b -> A(..b, b: 3)
  }
}
```

- Official: **error: Incorrect record update** (changing variant even with
  identical fields is rejected).
- glimpse: **OK**.

### 4.3 Duplicate fields in an update accepted
Official test: `errors.rs::duplicate_fields_in_record_update_reports_error`:

```gleam
pub type Wibble { Wibble(thing: Int, other: Int) }
pub fn main() {
  let wibble = Wibble(1, 2)
  let wobble = Wibble(..wibble, thing: 1, thing: 2)
  wobble
}
```

- Official: **error: Duplicate argument** (field `thing` updated twice).
- glimpse: **OK**.

### 4.4 Updating a type parameter across variants accepted
Official test: `errors.rs::inferred_variant_record_update_change_type_parameter_different_branches`.

```gleam
pub type Wibble(a) { Wibble(a: a, b: a) }
pub fn b_to_a(value: Wibble(a)) -> Wibble(Int) {
  Wibble(..value, a: 5)
}
```

- Official: **error: Unsafe record update** (the `a`/`b` type parameters are
  linked; overwriting `a` to `Int` while `b : a` comes from the spread is
  rejected).
- glimpse: **OK**.

**Root cause:** `record_update` (`typecheck.gleam` ~:1249) checks only that each
override field's label exists and unifies, and ignores the `..` spread variant
consistency entirely.

---

## 5. Field access on multi-variant types

### 5.1 Field that exists in only one variant
Official test: `errors.rs::field_not_in_all_variants`:

```gleam
pub type Person {
  Teacher(name: String, age: Int, title: String)
  Student(name: String, age: Int)
}
pub fn get_title(person: Person) { person.title }
```

- Official: **error: Unknown record field** (`title` is not on every variant).
- glimpse: **OK**.

### 5.2 Shared field at different positions across variants
Official test: `errors.rs::accessor_multiple_variants_multiple_positions`:

```gleam
pub type Person {
  Teacher(title: String, age: Int, name: String)
  Student(name: String, age: Int)
}
pub fn main(p: Person) { p.name }
```

- Official: **error: Unknown record field** (`name` is at a different position
  across the variants, so an accessor cannot be generated).
- glimpse: **OK**.

glimpse selects the field by the *first* matching variant only.

---

## 6. Function signatures: parameter label/ordering and duplicates

### 6.1 Duplicate anonymous-function parameter names
Official: `errors.rs::duplicate_anon_function_arguments`:

```gleam
pub fn main() { fn(x, x) { Nil } }
```

- Official: **error: Argument name `x` already used**.
- glimpse: **OK**.

### 6.2 Unlabelled parameter after a labelled one (signature ordering)
Official: `tests/errors.rs` (unlabelled argument after a labelled argument):

```gleam
pub fn main(wibble wibber, wobber) { Nil }
```

- Official: **error: Unlabelled argument after labelled argument**.
- glimpse: **OK**.

### 6.3 Positional argument after labelled ones in a call
Official: `errors.rs::positional_argument_after_labelled` (`X(b: 1, a: 1, 1)`).

- Official: **error: Unexpected positional argument after a labelled argument**.
- glimpse: **OK**.

**Root cause:** call-argument alignment and function-signature binding accept
any mix and unify positionally; the "no positional arg after a labelled arg"
restriction is not modelled.

---

## 7. Top-level definition checks

### 7.1 Duplicate constructor names in a custom type
Official: `errors.rs::duplicate_constructors3`:

```gleam
pub type Boxy { Box(Int) Box(Float) }
```

- Official: **error: Duplicate definition** (`Box` defined twice).
- glimpse: **OK** (only the module-level function/type duplicate set is checked
  for `DuplicateCustomType`, which is not this).

### 7.2 Private type leaking through a public signature
Official: `errors.rs::module_private_type_leak_1`:

```gleam
type PrivateType
@external(erlang, "a", "b")
pub fn leak_type() -> PrivateType
```

- Official: **error: Private type used in public interface**.
- glimpse: **OK** (no public-interface / visibility analysis).

### 7.3 `todo` inside a public constant
Official: `errors.rs::todo_in_a_constant_produces_an_error`:

```gleam
pub const wibble = todo
```

- Official: **error** (todo not allowed in constants).
- glimpse: **OK**.

### 7.4 Type alias with unused type parameters
Official: `type_alias.rs::alias_unused_parameter`:

```gleam
type A(a) = Int
```

- Official: **error: Unused type parameter `a`**.
- glimpse: **OK**.

---

## 8. `use <-` patterns must be irrefutable

`use` binds a single callback argument, so its pattern must be irrefutable.
Verified official verdict (gleam 1.18.0):

```gleam
fn apply_result(r: Result(Int, Nil), cb: fn(Result(Int, Nil)) -> Result(Int, Nil)) -> Result(Int, Nil) {
  cb(r)
}
pub fn main() { use Ok(x) <- apply_result(Ok(1)) x }
```

- Official: **error: Inexhaustive pattern** — missing `Error(_)`.
- glimpse: now reports **InexhaustivePattern** via the same exhaustiveness
  engine as `case` (`use_pattern_must_be_irrefutable` in
  `internal/typecheck.gleam`); the missing list names the uncovered
  constructor (`Error`) rather than the `Error(_)` value shape.
- Variable and discard patterns (`use x <- ..`, `use _ <- ..`) stay
  irrefutable and are accepted.

Note: the `todo`-based snippet previously recorded here
(`use [1, 2, 3] <- todo todo`) does not reproduce an exhaustiveness error in
real gleam 1.18.0 — it only warns about `todo` used as a function.

---

## 9. Patterns: spreading when it's unnecessary

Official: `errors.rs::unnecessary_spread_operator` — a constructor pattern that
lists *all* fields yet also has `..` is an error.

```gleam
type Triple { Triple(a: Int, b: Int, c: Int) }
pub fn main() {
  let triple = Triple(1, 2, 3)
  let Triple(a, b, c, ..) = triple
  a
}
```

- Official: **error: Unnecessary spread operator**.
- glimpse: **OK** — `PatternVariant._with_spread` is ignored entirely
  (`pattern.gleam:151`).

---

## 10. Tuple index bounds on an unknown value

Official: `errors.rs::tuple_index_not_a_tuple...` / `module_could_not_unify8`.

glimpse checks bounds only when the container type is concrete. When the value
is an unbound type variable the out-of-range index is silently accepted:

```gleam
pub fn main() {
  let z = todo
  fn(x) { x.2 }(z)
}
```

- Official: **error** (element index out of range / type mismatch).
- glimpse: **OK**.

(When the scrutinee is a concrete known tuple, e.g. `#(0, 1).2`, glimpse does
return an error — only the unbound-variable case is missed.)

---

## Summary of the divergence categories

Status is current as of the latest work; each "fixed" row is backed by tests in
`test/typecheck/`.

| # | Category | Official rejects, glimpse accepts | Status |
|---|----------|------------------------------------|--------|
| 1 | `echo` value type / identity | yes (also rejects good `echo` programs) | fixed (`echo_test.gleam`) |
| 2 | `case` exhaustiveness | yes | fixed for patterns, `let` and guards; empty `case` unparseable by `glance` (see §2.3) |
| 3 | bit-string option/size validation | yes (3 sub-cases) | fixed (`bit_string_test.gleam`) |
| 4 | record update variant/duplicate/linked-generic safety | yes (4 sub-cases) | fixed (`record_update_test.gleam`) |
| 5 | field access restricted to variant-stable fields | yes | fixed (`field_access_multi_variant_test.gleam`) |
| 6 | label ordering / duplicate param names | yes (3 sub-cases) | fixed (`parameter_ordering_test.gleam`) |
| 7 | duplicate ctor / private-leak / todo-in-const / alias params | yes | fixed (`top_level_checks_test.gleam`) |
| 8 | refutable `use` pattern | yes | fixed (irrefutability check via exhaustiveness engine) |
| 9 | unnecessary spread in pattern | yes | fixed (`pattern_spread_test.gleam`) |
| 10 | tuple-index bounds on unbound var | yes (bounds only applied to concrete tuples) | fixed (`expressions_test.gleam::tuple_index_on_unknown_type_test`) |

### Still open

- §2.3 **empty `case`**: `case b {}` is rejected, but at parse stage — the
  `glance` parser rejects an empty clause list (`UnexpectedToken(RightBrace)`),
  so the typechecker never sees it. The engine is ready to report the missing
  variants (`True`/`False`) if the AST becomes constructible.

---

## 11. Additional edge cases found by reviewing `compiler-core` 1.18.0

Each verdict below was verified by running the snippet through the real
`gleam check` CLI (gleam 1.18.0) and through the public
`glimpse.typecheck.module` API (Erlang target). "Official" is the CLI verdict.

### 11.1 Duplicate / missing variables in patterns — **fixed**

Official rejects; glimpse originally accepted (soundness gap). All four official
errors are in the "Duplicate/missing variable" family (`errors.rs`); glimpse now
reports `DuplicatePatternVariable` / `MissingPatternVariable` /
`ExtraPatternVariable`.

```gleam
pub fn a() { let #(x, x) = #(1, 2) x }
pub fn b() { case [1], 2 { x, x -> 1 } }
pub fn c() { case #(1, 1.0) { #(x, _) | #(_, x) -> 1 } }
pub fn d() { case [] { [x] | [] -> x _ -> 0 } }
```

- a/b: **Duplicate variable in pattern** (also `case X(..) { X(x, y, x) -> .. }`
  and `case [1] { [x, x] -> 1 }` — the latter is rejected by glimpse but as
  `InexhaustivePattern`, so the verdict happens to match).
- c: **Duplicate variable in pattern** (a variable bound in two or-alternatives).
- d: **Missing alternative pattern variable** (`x` is not bound by the `[]`
  alternative).

(`[x] | [x, y]` — **Extra alternative pattern variable** — is now reported as
`ExtraPatternVariable` too.)

### 11.2 Recursive type — **fixed**

```gleam
fn one(x) { two([x]) }
fn two(x) { one(x) }
pub fn main() { one(1) }
```

- Official: **Recursive type** (the mutual recursion forces `x = List(x)`).
- glimpse: now reports **RecursiveType** via constraint edges traced between
  functions' generic variables during the first pass, including cycles that
  run through pattern-bound variables (e.g.
  `f(xs) { case xs { [h, ..t] -> [f(t)] } }`) by tagging placeholder call
  returns. Well-typed self-recursion is still accepted (`f(x) { f(x) }`,
  `f(xs) { f([xs]) }`, list sum/map). The self-application case
  `let id = fn(x) { x(x) }` is rejected by both — glimpse with
  `InvalidArguments`.

### 11.3 Type-level misc — **fixed**

```gleam
pub fn main() -> Int() { 1 }
pub type A(a, a) = List(a)
pub type Two(a, a) { Two(a, a) }
pub type B { B(e0: Int, e0: Int) }
@external(erlang, "gleam_stdlib", "dict")
pub type Dict(key, value) { Dict(key: key, value: value) }
```

- Official: **Type used as a type constructor** / **Duplicate type parameter** ×2
  / **Duplicate label** / **External type with constructors**.
- glimpse: all **OK**. (Type holes are fine: `List(_)` in a param or return
  annotation is accepted by the official compiler too, and glimpse rejects type
  holes in type definitions.)

### 11.4 Duplicate module-level definitions — **fixed**

```gleam
fn dupe() { 1 }
fn dupe() { 2 }
const wibble = 1
pub const wibble = 2
```

- Official: **Duplicate definition** (functions and constants; also
  const/fn/external cross-pairs).
- glimpse: **OK** — only duplicate constructors are checked. (Duplicate custom
  type names and duplicate alias names are rejected by glimpse as
  `DuplicateCustomType`, so those verdicts match.)

### 11.5 Literal float out of range — **fixed**

```gleam
pub fn main() { 1.8e308 }
```

- Official: **Float outside of valid range** (also for `-1.8e308` and in
  patterns/constants).
- glimpse: **OK**.

### 11.6 Target support — **fixed**

```gleam
@external(javascript, "one", "two")
pub fn js_only() -> Int
pub fn main() { js_only() }
```

- Official (Erlang target): **Unsupported target** — a function with an
  external implementation only for another target cannot be called.
- glimpse: now rejects — public externals for other targets report
  `UnsupportedTarget` at the definition, and calls to private ones fail with
  `InvalidName` since they are not registered for the active target.

### 11.7 Incorrect number of case patterns — **fixed**

```gleam
pub fn main() { case 1 { _, _ -> 1 } }
```

- Official: **Incorrect number of patterns** (clause has more patterns than
  subjects; also `case a, b { x -> 1 }` with fewer).
- glimpse: now reports **IncorrectPatternCount**.

### 11.8 `let assert` message cannot use the pattern binding — **fixed**

```gleam
pub fn main() {
  let assert Ok(message) = Error("Not Message") as { "Uh oh: " <> message }
  message
}
```

- Official: **Unknown variable** — the `as` message is checked before the
  pattern binding is in scope.
- glimpse: now reports **InvalidName** (the message is typechecked before the
  pattern binds its variables).

### 11.9 False positive: curried pipe — **fixed**

```gleam
fn f2(a: Int) { fn(b: Int) { #(a, b) } }
pub fn main() { let x = 1 |> f2(1) x }
```

- Official: **OK** — the pipe fills the first missing argument of the outer
  call; since both are supplied the result is `#(Int, Int)`.
- glimpse: now **OK** — when every parameter is claimed by explicit arguments,
  the piped value is applied to the returned function (`InvalidArguments` only
  when the result is not a function).

### 11.10 Robustness: unresolved import panics — **fixed**

Calling `typecheck.module` with an import that is not present in the
dependency environment panics ("Missing modules should have been detected
before now", `internal/typecheck/imports.gleam:41`) instead of returning an
error.

### 11.11 Import resolution — **fixed**

Imports that collide on the same local module name (importing two modules that
share a last path segment, or aliasing two imports to the same name) are now
rejected with **DuplicateImport**. Importing a type-only name as a value (e.g.
`import wibble.{X}` where `X` is a type alias) reports **InvalidName**;
importing a constructor as a value stays fine. Private values and types of
dependency modules are not importable.

Interactions verified as already-correct in glimpse (not listed as bugs): guards
(Int vs Float operators, non-Bool guard), all operator type mismatches
(int/float/string), heterogeneous and mismatched-tail list literals, generic fn
return-vs-wing unification (`id(1, 1.0)`), tuple annotations with repeated
type-var in one tuple, `let assert` non-Bool, unknown variable names and unknown
record fields when the type is known, label on an unlabelled parameter, and
function types passed as first-class values.

No code was modified during this analysis; the only additions were transient
scratch probe programs under `dev/` which have been removed.