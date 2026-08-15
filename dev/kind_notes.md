# Kind notes (scratch, untracked — do not commit)

Live working log for the mutation-kind sweep harness (`dev/mutate_check.gleam`) and every
bug it has found in glimpse. Kept out of git so a context dump can't lose it.

## Command

```
gleam run -m dev/mutate_check -- --root <work_root> --src <src_rel> [--jobs <n>] [--kind <kind>] [--count] [--resume]
```

- `--kind` accepts comma-separated prefixes; `--count` lists mutant counts; `--resume`
  skips already-recorded gidx (1,012-mutant file resumes ~1s vs ~5min).
- After dev-module edits: `gleam format && gleam check` (dev modules are only checked, not tested).
- Verdict flow: real-gleam-rejects + glimpse-ACCEPTS = FALSE-NEG; glimpse-rejects + real-accepts = FALSE-POS.

## Kinds (prefixes in `counts_by_kind`, order in `mutate_file`)

Base 26: type, bool, binop, label, tuple, pattern, variant, bitstring, literal, arg,
lblarg, arity, negate, letpat, sigswap, pipe, casepat, clausepat, guard, typeparam,
bitreorder, letswap, importfn, use, import.

Round 1 (7): `capture` (2-arg call with one `_` hole -> swap spans), `pattern`-ext
(string/float swap in case patterns), `assert` (non-Bool into assert position),
`fn` (lambda arity drop), `listlit` (heterogeneous list), `tuptype` (`#(Int, String)`
swaps in annotations, both tokens primitive+different), `usepat` (swap `use X(p)` patterns).

Round 2 (4): `pipe2` (swap piped value with arg of a 2-arg call), `casepat2` (nested
tuple patterns via depth-aware `find_tuple_pattern_split`), `recupd` (record-update
`..base` rename / base-field swap), `bitsize` (bit-string segment size `:8`->`:89`).

Round 3 (6): `var` (rename Other-classified identifiers -> `name__zzz`; skips keyword
lines, `@` lines, spans inside string literals via `inside_string`), `constr` (swap
constructor field LABELS via `find_constr_fields`), `letassert` (RHS simple token ->
`"a"`/`1`), `fntype` (swap first param type <-> return type in `fn(..) -> ..` annotation
via `find_fn_annotation_swap`/`fn_type_close`; gates on `fn(`+`->`+`:`, distinguishes
lambda by `{`), `alias` (rename `as` alias on import lines), `pipestep` (swap piped
value with an arg of a LATER pipe stage via `find_pipe_step`). -> 41 kinds.

Round 4 (2): `attrib` (mutate attribute arg shapes on `@` lines — `var` skips them:
external drop-module/add-fn/string-target, deprecated drop-msg/int-msg, target
add-arg/string-name, internal add-arg), `const` (const value -> `fn() { 1 }` / `{ 1 }`
/ `1 + 1`). -> 43 kinds.

Round 5 (1): `constrdup` (rename a variant constructor to collide with another type's,
via `find_collision_target`/`find_type_blocks`/`block_constructors`/`constructor_lines`/
`uppercase_spans_after`). -> 44 kinds.

Round 7 (4): `guardexpr` (wrap guard operand in tuple/list/negation/field-access),
`bitsizepat` (`<<x:size(8)>>` -> `size(y)`), `concatpat` (swap string-concat pattern
operands), `pipefn` (rename first param of a piped fn literal). -> 48 kinds.

Round 12 (3): `extann` (drop param/return annotation — real rejects only for EXTERNAL
fns; finders: `find_param_annotation`, `find_return_annotation` where prev-non-space is
`)`), `exthole` (type token -> `_` in external signatures), `attrplace` (prepend
misplaced `@internal`/`@target(javascript)`/`@external(erlang,"a","b")`). -> 51 kinds.

Also in sweeps: `worddel`, `wordswap` (~56 kinds total). New kinds MUST produce NOVEL
mutant sources or `dedup` (line 435, keys on m.1 source, first-writer-wins) drops them.

Verification facts: stdlib has NO real `assert` statements (only `//// assert` doc
comments) and NO `use X(p) <-` — assert/usepat need synthetic modules (sample at
/tmp/mutcheck/assertroot/src/assertuse.gleam). Tuple annotations `-> #(` DO exist
(dict, result, pair, bit_array, set, uri, dynamic/decode, list).

## Bugs found & fixed (all regression-tested; error variants in src/glimpse/error.gleam)

### Escape bug (round 1, before bug numbering)
lustre `server_component.gleam:159` `listlit ->int` mutated `\"` to `1` in a JS string ->
invalid escape `\1`. Real gleam rejects; glimpse accepted. ROOT CAUSE: glexer `lex_string`
captures raw content, never validates escapes; `unescape_string` (Result(String, Nil))
uncalled. FIX: glexer added as direct dep (`glexer = ">= 2.5.0 and < 3.0.0"`); new
`InvalidEscape(value)`; Expression.String and PatternString sites call
`glexer.unescape_string`. Real gleam rejects bad escapes in BOTH regular and `"""` raw
strings (so `"""C:\path"""` rejected, `"""C:\\path"""` accepted). Re-judged 0/52.
Always verify escapes with FRESH project dirs (build-cache artifacts mislead).

### Class A: record updates + rigid type-var linkage (round 3)
- Bug 1: record-update result lost distinct signature type vars — `record_update()` used
  TWO independent `types.instantiate_callable` calls. FIX: one instantiation; base unifies
  against `constructor_return` only at type-param positions the update does NOT set
  (`updated_record_type_positions` + `types.unify_record_update_base` + `types.resolved_var_id`).
- Bug 2: phantom type-param updates wrongly unified. Position left free iff (a) NO field
  references it (phantom; real gleam leaves it free — birdie `Snapshot(..snapshot, info: x)
  |> serialise` piping `Snapshot(Accepted)` into `fn(Snapshot(New))` is VALID), or
  (b) every referencing field is updated (`set.is_subset`).
- Bug 3: shared-type-param incomplete record updates wrongly accepted (real: "Incomplete
  record update... same type variable used for multiple fields"). Base annotated
  `App(arguments, model, message__zzz)` must fail against return `App(arguments, model, message)`.
- Bug 4: unknown @external target — new `UnknownExternalTarget(name)`; module() validates
  every @external; match must be `[glance.Variable(_, name), ..]` (a single-element
  pattern silently never fires).
- Bug 5: unknown attribute name — `UnknownAttribute(name)`; valid: deprecated/target/
  internal/external. `all_module_attributes` + `is_known_attribute`.
- Bug 6: rigid-var linkage lost when record-update result passed as a call arg.
  `unify_record_update_base` now uses `resolve_keep_rigid` on both inputs.
- Bug 7: same lost in `use` continuation. internal typecheck.gleam:230 `check_continuation`
  ended with plain `types.resolve` -> `resolve_keep_rigid`.
- Bug 8: lambda annotation not reusing enclosing rigid type param. Environment gains
  `generic_vars: dict.Dict(String, Type)` (types.gleam:1146); `fn_literal` (internal
  typecheck.gleam:977) starts from `environment.generic_vars` and re-substitutes via
  `types.substitute_type_variables`. Needs a POLYMORPHIC const + field-value lambda whose
  annotation names the enclosing fn's type param to reproduce.
- Bug 9: function capture generalises rigid vars — `do_generalise` (types.gleam:1044-1058)
  Var case followed the Link of any `Var(id)`. FIX: check `is_rigid_var` first,
  `resolve_keep_rigid`.
- Bug 10: pipe-into-capture loses linkage — capture.gleam `fn_capture` (line 128) built the
  type with plain `types.resolve` -> `resolve_keep_rigid`.
- Bug 11: recursive self-call not monomorphic. Real gleam checks a recursive self-call
  against the fn's OWN rigid vars (not a fresh instantiation). Environment gains
  `current_function`; call() substitutes the callee signature's GenericTypeVariables with
  `environment.generic_vars` for self-calls. Guard needed: callee must not be a
  placeholder_callee, else FALSE-POSITIVES on recursive stdlib helpers like `max_loop`.

### Architectural fix: first-class rigidity (covers bugs 6-11, 22)
Rigidity was NOT part of the type representation (lived only in transient
`var_sources`/`generic_vars`); any operation touching a type could collapse a rigid Var
to its name and destroy linkage. NEW: `GenericTypeVariable(name: String, rigid: Bool)`.
`freshen_generics` links a fresh rigid var to `GenericTypeVariable(name, True)`;
`is_generic_type` returns `!rigid`; `do_instantiate`/`do_generalise` keep `True` as-is;
stored signatures keep `(name, False)` so cross-module calls instantiate afresh;
`strip_rigidity` True->False (used when an annotated lambda's params become its own
polymorphic type). Call-site patches (bug 22's `is_generic_callable` in functions.gleam,
the `check_arguments` special-case) REMOVED — plain `is_generic_type` now returns False
for `CustomType(Decoder, [GenericTypeVariable("message", True)])`. Transient helpers kept:
`resolve_keep_rigid`, `is_rigid_var`, `unify_rigid`, do_generalise Var-case rigid check.

### Round 4 (attribute shapes, constants, record-update labels)
- Bug 12: anonymous fns not allowed in constants — any `fn` literal in a const value
  (even nested in a variant) is a parse error. `constant_has_fn` -> new `FnInConstant`.
  Named-fn references fine.
- Bug 13: constants restricted to a strict grammar (`parse_const_value_unit`): only
  Int/Float/String literals, Variable refs (possibly qualified), Tuple/List/BitArray of
  constants, `Name(args)` construction + `Name(..base, args)` updates, `<>` concat,
  numeric-neg literals. NOT: other binops, blocks, case, fns, captures, tuple index,
  field access on non-vars, panic. Replaced `constant_has_todo`/`constant_has_fn` with
  recursive `constant_value_error` -> `TodoInConstant`/`FnInConstant`/`InvalidConstantExpression`.
- Bug 14: record update on a constructor with no labelled fields —
  `RecordUpdateOnUnlabelledConstructor(constructor)` when `dict.is_empty(labels)`.
- Bug 15: @external shape must be exactly `[Variable, String, String]` ->
  `InvalidExternalAttribute`; bad Variable name keeps `UnknownExternalTarget`.
- Bug 16: @deprecated (exactly one string), @target (exactly one variable), @internal
  (no args) -> `InvalidAttributeShape`. `@target(python)` deliberately still accepted
  (design choice, NOT a FALSE-NEG).

### Round 5
- Bug 17: cross-type constructor name collision (`pub type X { A } pub type Y { A }` =
  "Duplicate definition") -> `DuplicateConstructor`.
- Bug 18: public body-less external for another target -> `UnsupportedTarget`; wired
  `target.function_supported` (was dead code).
- Bug 19: duplicate attributes -> `DuplicateAttribute`. @external keyed by first arg
  (target), so erlang+javascript OK but same-target not; other attributes at most once.
  Scopes: one each per import/function/constant/type-alias; custom type + variants share one.
- Bug 20: bit-array segment options `signed`/`unsigned` (pattern-only) and `unit`
  (needs explicit size) in EXPRESSIONS -> `InvalidBitStringSegment`.
- Bug 21: todo/panic messages not typechecked; `todo(x)`/`panic(x)` parse as
  `Call(Todo, [x])`. FIX: `check_todo_message` + Todo/Panic callees in `call()` -> `TodoType`.
- Bug 22: rigid signature var lost on return — `check_arguments` instantiated any arg whose
  type `is_generic_type` (incl. concrete `Decoder(message)` where `message` is the caller's
  rigid signature var). FIX: narrowed to `functions.is_generic_callable`
  (CallableType/GenericCallableType only); later removed by the architectural fix.
- Harness: name_spans end-of-line flush fix (base case never flushed a word running to EOL).

### Round 7 (coverage-guided probing; Erlang `cover` in worktree /tmp/mutcheck/coverage-wt, branch coverage-instrument)
- Bug 23: bit-string size variable must be Int — `check_bit_array_size_variables` unifies
  size var with Int -> `InvalidType("String","Int","size variables must be Int")`.
- Bug 24: `bytes`/`binary` options accepted in bit-string EXPRESSIONS (patterns only).
  Glance aliases binary->BytesOption, bit_string->BitsOption; `check_expression_options`
  rejects BytesOption like Signed/Unsigned.
- Bug 25: out-of-bounds tuple index on an INFERRED tuple (`id(#(1,2)).2`) accepted by
  growing the tuple. Removed extend_tuple growth -> UnexpectedType.
- Bug 26: let-bound capture of a polymorphic fn (`let f = wrap(_)`) stayed polymorphic;
  real gleam makes shared captures monomorphic (let-bound fn NAMES instantiate once).
  FIX: fn_capture stops generalising, keeps fresh flexible vars; direct capture exprs
  still polymorphic. Rejected instantiate-at-let-binding: real gleam KEEPS annotated
  polymorphic lambdas polymorphic when let-bound.

### Round 8 (new-codebase sweeps; gleam_otp + gleam_json clean, squirrel found 5)
- Bug 27 (FP): bit-string size var referencing an EARLIER segment falsely rejected —
  `check_segments` passed the stale outer env to size checks instead of the threaded `env`.
- Bug 28 (FP): `to_glance` stripped the `gleam` qualifier on prelude types even when a
  local type/alias shadows it (glint `snag.Result`). New `local_type_is_same`.
- Bug 29 (FN, 134): String-literal bit-string PATTERN segments allowed size/type options
  (`<<"P":8, rest:bytes>>`) — implicit utf8 can't take size. `check_pattern_segment_options`
  handles PatternString.
- Bug 30 (FN): use-pattern arity mismatch via `_` hole return annotations. FIX: resolve
  holes into the stored signature on `option.Some` unify success (only when annotation
  contains a hole, to preserve source spans).
- Bug 31 (FN): duplicate parameter names in fn definitions — module() checks via
  `intern.find_duplicate` -> `DuplicateArgumentName`.
- Bug 32 (FN): body-inferred unannotated param types not enforced at call sites —
  `option.Some` branch writes back inferred param types (only unannotated, preserving
  annotated spans).

### Rounds 9-10 (real-library FALSE-POSITIVE sweeps + target support)
- Bug 33 (FP): lambda ANNOTATION generic referenced through an UNANNOTATED param splits
  into poly vs pinned rigid -> pipe-into-capture `InvalidType("List(var_NN)", "a", ...)`.
  FIX: fn_literal resolves+strips+substitutes ALL params.
- Bug 34 (FP): lambda param shadowing a RECURSIVE function name fired the recursive
  self-call branch on the shadowing param (non-callable). Recursive branch only when the
  callee's definition is the current function's callable.
- Bug 35 (FP): target-support enforced on DEPENDENCY modules. Real gleam only enforces
  for the root package (`TargetSupport::Enforced` vs `NotEnforced`). FIX:
  `check_target_support` Bool param on typecheck.module (deps False).
- Target support full impl (ae477c3, 31a2ef1, e7373d5): `narrow_implementations`
  equivalent — root code may not CALL or even REFERENCE a fn unavailable on the active
  target; same-module calls propagate (scanner fixpoint PRE-INJECTED before body checking);
  scope-aware scanner (shadowing by let/param/pattern/lambda/use binding);
  current-function-external exemption (body dead on target when a matching external
  exists). New `TargetSupport` type + targets.gleam module + `current_function_external`
  env field.
- Bug 36 (FN): same-module unsupported-function calls NOT caught (fixpoint ran after body
  passes). Pre-inject + scope-aware scanner.
- Bug 37 (FN): dep fn that merely REFERENCES a restricted value was not narrowed (real
  gleam narrows via references even under NotEnforced). Scanner counts Variable/FieldAccess
  references as callees.
- Bug 38 (FP): pipe into todo/panic rejected (NotCallable) — `pipe_value_into_callable`
  resolves TodoType targets, checks args as expressions.
- Bug 39 (FN): labelled args to todo/panic accepted -> `UnexpectedLabelledArgument` at
  call() and the pipe TodoType branch.
- Bug 40 (FN): @target(python) accepted -> `UnknownTarget` on raw module (erlang|javascript
  only); `target.Named()` extension is dead.
- Bug 41 (FN): import cycles unreachable from any root escaped — `sort_from_all_roots` sorts
  from ALL module keys, not just nothing-imports-them roots.
- Bug 42 (FN, 62 on plinth): external fns with unannotated params/returns ->
  `MissingParameterAnnotation`/`MissingReturnAnnotation` on raw module (no discard exemption).
- Bug 43 (FN, 4): type holes (`_`/`_foo`) in external signatures ->
  `UnexpectedTypeHole` (nested-inclusive walk via `type_hole`/`first_type_hole`).
- Bug 44 (FN, 30 amber): @external on custom types/variants/aliases/imports unvalidated
  (type-level `@external(javascript,"..","ChildProcess$")` pattern). `external_scopes`
  covers all 5 scopes; variant/alias/import -> `ExternalAttributePlacement(scope)`.
- Value-flow verification (5218a16): restricted dep fn values keep restriction through
  `get()()`/`id_(get)()()`/`pure call_it` — 3 regression tests; bug-37 scanner reference-
  counting already closed the dynamic-tracking gap (14 differential probes consistent).

### Round 11 (attribute placement matrix)
- Bug 45: @external/@internal/@target placement. Real rules (all empirically verified):
  @deprecated everywhere; @target everywhere except variants; @internal only on PUBLIC
  decls (fn/const/type/alias) or imports; @external only on fns (pub/private) and bodyless
  types — rejected on constants (pub AND private), variants, aliases, imports. New
  `InvalidAttributePlacement(attribute, scope)`; ExternalAttributePlacement doc corrected.
  FALSE-POSITIVE pitfall: `@internal pub const` IS valid (gleam_time pattern) — the
  public-flag branch was essential.

### Round 13 (overnight sweep first-hit fixes; committed 717826e)
- Bug 47a (13 FN, wordswap): corrupted @external(javascript) module paths accepted
  ("Invalid JavaScript module" in real). FUNCTION-level JS externals validate module path
  `[a-zA-Z0-9_./:-]+` and fn name `[a-zA-Z_][a-zA-Z0-9_]*` (errors
  InvalidExternalModule/InvalidExternalFunction); TYPE-level exempt (JS class names like
  MessageEvent$ — gossamer); erlang externals never validated. Probed: type-level even
  accepts module "a b" + fn "1x".
- Bug 47b (4 FP, extann): MissingParameter/ReturnAnnotation + UnexpectedTypeHole fired for
  externals NOT covering the active target (js-external under erlang with a Gleam body).
  Gated: external must apply to active target (`types.target_supports(target,
  targets.external_support(definition))`). Probed: private bodyless other-target externals
  ACCEPTED; @target(javascript) body-ful fns ACCEPTED with no annotations.
- Bug 48 (4 FP, var): glexer lexed `_` in UPPERCASE names as DiscardName (Foo_bar -> Foo +
  _bar). Real rules: lexer allows `_` everywhere, but DEFINITION-SITE rejects `_` in custom
  type names, variant names, type alias names. FIX: vendored glexer 2.5.0 at
  third_party/glexer (path dep) with lex_uppercase_name accepting `_`; glimpse validates
  names on raw_module. (Restored glexer_ffi.erl — hand-written FFI wrongly stripped as a
  "compiled artifact"; missing it caused runtime Undef in lex_string, corrupting sweeps.)

### Rounds 14-16 (misc sweep findings)
- Unlabelled fields after labelled fields (amber, 60+ FN across 13 files, worddel): in (a)
  type-definition variant fields and (b) constructor PATTERNS (real: "Unlabelled argument
  after labelled argument"). FIX: `fields_unlabelled_after_labelled` in pattern.gleam
  (PatternVariant) + `variant_fields_unlabelled_after_labelled` in typecheck.gleam raw-module
  check. Construction calls were already covered.
- List tail without comma after element (glam/doc, 6 FP, var `,__zzz ..rest`): real allows
  `[a, b, x ..rest]` and `[1, 2, 3 ..xs]` (exprs too). FIX: two new cases in
  third_party/glance list() (discard-tail + named-tail after an element).
- Duplicate selective-import members (gleam_otp/actor, 9 FN): raw-module check via
  intern.find_duplicate over unqualified_types/values (UnqualifiedImport.name). GOTCHA:
  `import` is a keyword — lambda param must be named `member`; closure params need explicit
  `List(glance.UnqualifiedImport)` annotation.
- bitstring PATTERN options (mist/http2/frame, 6 FN): `utf8/utf16/utf32` with a size (or on
  a named var) rejected; negative `unit()`/`size()` values rejected. Expression side already
  had these.
- Implicit signature type variables camelCase (gleam_otp/factory_supervisor, glisten/tcp):
  `child_dataInt` in fn params/returns accepted -> now InvalidTypeVariableName.
- Opaque variant constructors by name in CONSTANTS (gleam_otp/supervision, 1 FP):
  `const x = supervision.Transient` with `pub opaque type Restart` accepted; `in_constant`
  env flag allows it for const values.
- case-pattern variable names camelCase (mist/clock, `etTime`): now rejected (let-pattern
  check didn't cover case clauses).
- in_constant leak (mist/clock pub-deletion + glint/utils): the const fix set
  `in_constant: True` and LEAKED it out of constant_ into every later check — any module
  WITH a constant resolved private cross-module refs via the relaxed fallback. FIX: env
  reset to in_constant=False after the const VALUE check. (Only the full 15-module mist
  package reproduced; 2/3-module mirrors rejected.)
- Positional constructor-pattern args bind the NEXT FREE field (mist/http2/handler, 1 FP):
  real gleam's field_map.reorder moves labelled args to named positions, so a bare positional
  arg binds the next unused slot, not the raw index. `Data(identifier, data: data, end_stream:
  end_stream)` on `Data(data, end_stream, identifier)` binds identifier -> the identifier
  field. First attempt 92b0927 (bare-name name-match) exploded to 399 FPs — superseded by
  f5efd9a. Real gleam NEVER name-matches bare pattern args; only `name:` binds by label.
- camelCase name validation (6c63705): InvalidFunctionName/InvalidConstantName/
  InvalidArgumentName/InvalidTypeVariableName/InvalidVariableName — lowercase identifiers
  (vars/consts/fns/args/type-vars) may not contain uppercase; import aliases exempt. Lexer
  fix: lex_lowercase_name accepts A-Z (the typeField bug).

### Accepted divergence (jot, round 17 — decided with user)
1 FP: `extann param-drop` deleting `: Splitters` from `fn parse_inline(... splitters:
Splitters ...)` makes the body do `splitters.inline` on an unannotated param. Real 1.18.1
accepts it ONLY in the full jot package; every minimal repro rejects ("Unknown type for
record access") and gleam main hard-errors (expression.rs RecordAccessUnknownType). glimpse
rejects (InvalidFieldAccess). DECISION: match gleam main (arguably more correct); do not
implement deferred record-access resolution. jot accepted as 0 FN / 1 FP (accepted).

## Sweep history (mutant volumes)

- Round 1: stdlib/lustre/wisp 49 files, 62,315 mutants, 1 FALSE-NEG (escape bug). list.gleam
  8229 mutants: capture 1, fn 92, listlit 349, pattern 384 fired; assert/usepat/tuptype 0.
  Zero-count kinds verified on synthetic/suitable files: tuptype 1/1 (uri.gleam:514), assert
  1/1, usepat 1/1. Earlier `listlit ->string 1/349` was harness corruption (concurrent
  worker dirs), NOT a glimpse bug.
- Round 2: lustre 26 files, 28,923 mutants, ALL 0 FN (incl. server_component 0/1733).
- Round 3: 8 bugs found (record-update/rigid-var class). All 26 lustre files clean after bug 8.
- Full 44-kind sweep (9 Aug, jobs=8, 3h06m): 49 files (stdlib 19, lustre 26, wisp 4),
  280,440 mutants, 6 FALSE-NEGs, ONE Class-B bug, fixed (f0f38db): attribute checks +
  const-grammar ran on the target-FILTERED module; real gleam validates at parse time
  before filtering. FIX: run attribute checks (known/shape/duplicate/external) + const
  grammar on the RAW module; type-level checks (DuplicateDefinition, DuplicateConstructor,
  UnsupportedTarget, ExternalTypeWithConstructors) correctly STAY on the filtered module.
  Rigid-flag refactor (a06518d) introduced ZERO FN across all 280,440.
- Round 7: guardexpr/bitsizepat/concatpat/pipefn over stdlib+lustre: 0 FN (~500 mutants,
  11 files, 10 min).
- Round 11 totals: ~390k mutants, zero FALSE-NEGs across stdlib, lustre, plinth, amber,
  gossamer, sqlight (4 idiom profiles: erlang stdlib, lustre UI, JS FFI, type-level JS FFI,
  DOM JS, sqlite FFI). sqlight 0/4211; gossamer 66/66 files clean (55 files 0/69798 + 11
  intl re-swept 0/29838 — intl ran during a mid-edit compile-error window, re-run clean).
  Discarded: ffmpeg 0.0.1 (broken against gleamyshell, real gleam rejects baseline); node/
  deno/gleam_nodejs not on hex.
- Round 12 (extann/exthole/attrplace only): 22 roots, 22,938 mutants, ZERO FN. Corpus:
  stdlib 2057, lustre 3282, plinth 1411, amber 761, gossamer 4081, sqlight 258, gleam_otp
  545, gleam_crypto 86, mist 1677, wisp 991, glisten 758, justin 39, glemplate 263,
  shellout 89, birl 768, jot 1146, tom 520, glam 245, simplifile 336, argv 11, glint 631,
  lily 2983. Strongest convergence evidence: kinds aimed at exact bug 42-45 shapes found
  zero new bugs across 22 codebases.
- Round 13: overnight sweep first file bit_array 13 FN + 9 FP -> bugs 47a/47b/48; re-judged
  bit_array 0/8405, 0 FP. Sweep RESTARTED 22:39 with fixed code (early files stale).
- Round 13b: sweep part 2 (21 roots: lustre..lily) re-launched 08:39, ~30h est.
- Round 14: amber 60+ FN / glam 6 FP / actor 9 FN all fixed; actor 2 FP REMAIN
  (empty-continuation use in case-clause block — real accepts in a context that resisted
  ~8 probe attempts; replicas all rejected too). dev_check SELF-CHECK broken since vendoring
  (path deps not in build/packages; "MissingImportError(glance)") — does not affect sweeps
  (they use `--typecheck <root>`).
- Round 15: re-judged single-threaded: plinth event 0/1596, file_system 0/1513, geolocation
  0/1694, message_event 0/391, storage 0/711, glemplate/ast 0/1264, lily/client 0/36716,
  lily/component 0/39681. camelCase + round-14 fixes resolved every finding.
- Round 16 (12-root batch: mist, wisp, glisten, sqlight, gleam_otp, shellout, birl, jot, tom,
  glam, simplifile, glint; jobs=8): ~36 FN + ~10 FP across mist, glisten, gleam_otp, jot,
  sqlight, glint — all fixed and re-judged clean; wisp/shellout/birl/tom/glam/simplifile
  clean. jot re-judge (35,160 mutants): first overnight run OOM-killed by macOS before
  verdict consolidation — NO result; relaunched crash-safe.
- Round 17: jot re-judge (jobs=8, crash-safe): 30,171/35,160 judged (slow tail from
  pathological mutants that make gleam check take minutes) -> 0 FN, 1 FP (accepted
  divergence). Batch's 4 FNs closed by the session's fixes.

## Harness notes / gotchas

- Worker-dir keying: dirs are `root.<src-with-/->_>.w<i>.<token>`, token = nanosecond
  `date +%s%N` via shellout (fallback pid). Concurrent invocations against the same root
  otherwise corrupt each other's worker copies.
- NEVER run two mutate_check invocations CONCURRENTLY on the SAME root (22 FN + 3 FN that
  vanished on clean re-runs). Different roots in parallel are fine.
- Durable crash safety (9b8c9f2): each worker appends `gidx\tverdict` to a per-worker file
  (/tmp/mutcheck/results.*) + FN/FP records to a matching records file; the tally aggregates
  from those files. A crash loses only the in-memory tally, never judged work.
- falsepos.txt/falsenegs.txt accumulate and interleave under concurrent workers — regenerate
  deterministically with --jobs 1 for exact mutants.
- falsenegs.txt: mutant sources contain blank lines, so `grep -c "FALSE-NEG ::"` counts
  blocks, not split-on-blank-line.
- name_spans fix (5201cce) cut mutant volumes: garbage-span bug emitted a span on every
  non-word char after a word with stale start=0 and growing length (incl. full-line EOL
  spans); worddel/wordswap/var counts collapsed (wisp.gleam 61,698 -> ~27,500). Same commit
  fixes dev_check self-check: scan_build_packages also scans third_party/ (vendored path deps).
- Speed: ~all runtime is `real` (per-mutant `gleam check` subprocess spawn, ~300ms/mutant);
  glimpse is ~0ms. dev/monotime.gleam: monotonic_time() via @external(erlang, "erlang",
  "monotonic_time"); module named `monotime` (timer collides with Erlang stdlib); dev
  modules use BARE import names.
- `gleam clean` + deps download needed after switching glexer/glance to path deps.
- `git add -A` is dangerous here (stages kind_notes.md + src/kdbg.gleam leftovers).
- Vendoring: third_party/glexer (2.5.0) + third_party/glance (7.0.0), both path deps in
  gleam.toml. When vendoring, remove compiled .erl/.app.src artifacts but KEEP hand-written
  FFIs (glexer_ffi.erl). README documents each patch + re-apply note. Patches: glexer
  lex_uppercase_name accepts `_`; glance rejects `opaque` on alias-form types, allows list
  tail without comma, parses body-less cases.
- Coverage instrumentation (round 6): Erlang cover in worktree /tmp/mutcheck/coverage-wt
  (branch coverage-instrument; scratch files cov_run.escript/cov_map.py/cov_report.py/
  cov_erlview.py). 83.6% (3053/3654) -> ~85.8%. Lowest: bit_string_segment 65.4%, pattern
  74.1%, calls 77.2%, types 78.2%. Dead paths probed in rounds 7-8 (all matched real gleam;
  NamespaceType do_instantiate case dead-by-construction).
- Round 13b glance fixes: body-less `case x` (clauses=None, errors only at ANALYSIS
  "Missing case body", never for target-filtered fns) parsed with empty clauses; analysed
  body-less cases still rejected (InexhaustivePattern). Exhaustiveness deferred when any
  case subject resolves to Var/InferredReturn/TodoType; second body pass re-checks with
  resolved signatures (real gleam checks exhaustiveness after all bodies analysed).

## Status / pending (end of round 17)

HEAD 9b8c9f2, 734 tests, clean tree except this file. ~56 kinds wired. All sweeps closed;
jot's sole FP is the accepted divergence; jot tail still grinding in background.
