import glance
import gleam/dict
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import glimpse/internal/typecheck/types

/// How many times a recursive type may expand into itself while computing a
/// subject's mode. Deeper expansions of list tails and recursive custom type
/// fields become `Infinite`, which keeps the mode finite while still allowing
/// patterns like `[first, second]` to split the tail into `[]` and `[..]`.
const mode_expansion_depth = 8

fn seen_count(seen: List(String), name: String) -> Int {
  list.fold(seen, 0, fn(count, item) {
    case item == name {
      True -> count + 1
      False -> count
    }
  })
}

/// Decision-tree exhaustiveness checking, mirroring the algorithm the official
/// Gleam compiler uses (`compiler-core/src/exhaustiveness.rs`), which is based
/// on Luc Maranget's "Compiling Pattern Matching to good Decision Trees" and
/// Jules Jacobs' "How to compile pattern matching".
///
/// A `case` expression is turned into a matrix of rows, one per clause
/// alternative. Each row is a set of checks on distinct subjects; a check pairs
/// a subject identifier with the reduced pattern it must match.
///
/// Each step drops the unconditional patterns from every row. A row that
/// becomes empty matches everything, so the whole case is then exhaustive.
/// Otherwise a subject is split on, depending on the subject's type:
///
/// - Infinite types (Int, Float, String, BitArray, functions, unbound
///   variables) can never be exhausted by finitely many literals, so the case
///   is exhaustive only when some row matches the subject unconditionally.
/// - Finite types (custom types, Bool, lists, tuples) split into one sub-matrix
///   per constructor; the case is exhaustive exactly when every constructor's
///   sub-matrix is.
///
/// Every split consumes the subject it divides on within each sub-matrix, so
/// the search terminates.
/// A pattern reduced to the fragments that matter for exhaustiveness.
type Pat {
  /// Matches any subject (variable, discard, `as` binding).
  Any
  /// Matches a single literal (Int, Float, String, bit array, string prefix).
  Literal
  /// Matches a constructor, with its arguments reduced against the field types.
  Constructor(index: Int, arguments: List(Pat))
}

/// How a subject branches when split.
type Mode {
  /// Types that only a catch-all can cover.
  Infinite
  /// Custom types, Bool, lists and tuples: a known set of constructors.
  Finite(List(Field))
}

/// One constructor of a Finite type, together with the modes of its fields.
type Field {
  Field(name: String, modes: List(Mode))
}

/// A compiled row of the pattern matrix.
type Row {
  Row(checks: List(#(Int, Pat)))
}

/// A missing value pattern: the catch-all `_`, or a constructor with the
/// missing patterns of its arguments.
type MissingPattern {
  AnyMissing
  ValueMissing(name: String, arguments: List(MissingPattern))
}

/// The outcome of checking a matrix.
type Outcome {
  Outcome(missing: List(MissingPattern), next_id: Int)
}

/// Render a missing value pattern the way the official compiler prints it:
/// `Error(_)`, `Ok(False)`, `[_, ..]`, `#(_, _)`, `Two`, `_`.
fn render_missing(pattern: MissingPattern) -> String {
  case pattern {
    AnyMissing -> "_"
    ValueMissing(name, arguments) ->
      case name {
        "#" ->
          "#(" <> string.join(list.map(arguments, render_missing), ", ") <> ")"
        "[..]" -> "[_, ..]"
        "[]" -> "[]"
        "element" ->
          "#(" <> string.join(list.map(arguments, render_missing), ", ") <> ")"
        _ ->
          case arguments {
            [] -> name
            _ ->
              name
              <> "("
              <> string.join(list.map(arguments, render_missing), ", ")
              <> ")"
          }
      }
  }
}

/// The element at `index` of `items`, or `None` when out of bounds.
fn at(items: List(a), index: Int) -> option.Option(a) {
  case items {
    [] -> option.None
    [head, ..tail] ->
      case index {
        0 -> option.Some(head)
        _ -> at(tail, index - 1)
      }
  }
}

/// The integers from `from` (inclusive) up to `upto` (exclusive).
fn range(from: Int, upto: Int) -> List(Int) {
  case from < upto {
    True -> [from, ..range(from + 1, upto)]
    False -> []
  }
}

/// Check whether the given clause alternatives (each a list of patterns, one
/// per subject) exhaust the possible values of the subjects. Returns the
/// missing value patterns, or `None` when the case is exhaustive.
pub fn check(
  environment: types.Environment,
  subject_types: List(types.Type),
  alternatives: List(List(glance.Pattern)),
) -> option.Option(List(String)) {
  let modes = list.map(subject_types, fn(type_) { mode_of(environment, type_) })
  let ids = range(0, list.length(subject_types))
  let rows =
    list.map(alternatives, fn(alternative) {
      let triples = list.zip(list.zip(ids, modes), alternative)
      let checks =
        list.fold(triples, [], fn(acc, pair) {
          let #(ids_and_modes, pattern) = pair
          let #(id, mode) = ids_and_modes
          case reduce(mode, pattern) {
            Any -> acc
            reduced -> [#(id, reduced), ..acc]
          }
        })
      Row(checks)
    })
  let initial_modes = dict.from_list(list.zip(ids, modes))
  let Outcome(missing, _) =
    compile(initial_modes, rows, list.length(subject_types))
  case missing {
    [] -> option.None
    _ -> option.Some(list.map(missing, render_missing))
  }
}

/// Compute the mode of a program type: how it branches when split. The `seen`
/// lists the custom type names currently being expanded so that recursive types
/// recurse into an `Infinite` mode instead of looping forever.
fn mode_of(environment: types.Environment, type_: types.Type) -> Mode {
  mode_of_guarded(environment, [], type_)
}

fn mode_of_guarded(
  environment: types.Environment,
  seen: List(String),
  type_: types.Type,
) -> Mode {
  case type_ {
    types.IntType
    | types.FloatType
    | types.StringType
    | types.BitArrayType
    | types.Var(..)
    | types.GenericTypeVariable(..)
    | types.InferredReturn
    | types.CallableType(..)
    | types.GenericCallableType(..)
    | types.NamespaceType(..) -> Infinite
    // `Nil` is a custom type with a single constructor, so a `Nil` pattern
    // covers every value of a `Nil`-typed subject.
    types.NilType -> Finite([Field("Nil", [])])
    types.BoolType -> Finite([Field("True", []), Field("False", [])])
    types.TupleType(elements) ->
      Finite([
        Field(
          "element",
          list.map(elements, fn(e) { mode_of_guarded(environment, seen, e) }),
        ),
      ])
    types.CustomType("gleam", "List", [element], _) ->
      case seen_count(seen, "List") >= mode_expansion_depth {
        True -> Infinite
        False ->
          Finite([
            Field("[..]", [
              mode_of_guarded(environment, seen, element),
              mode_of_guarded(environment, ["List", ..seen], type_),
            ]),
            Field("[]", []),
          ])
      }
    // The prelude `Result` pre-registers no variant index on its constructors,
    // so build its `Ok`/`Error` fields from the concrete type arguments.
    types.CustomType("gleam", "Result", [ok_type, error_type], _) ->
      Finite([
        Field("Ok", [mode_of_guarded(environment, seen, ok_type)]),
        Field("Error", [mode_of_guarded(environment, seen, error_type)]),
      ])
    types.CustomType(module, name, parameters, _) ->
      case constructors(environment, seen, module, name, parameters) {
        option.Some(fields) -> Finite(fields)
        option.None -> Infinite
      }
    types.TypeAlias(_, aliased) -> mode_of_guarded(environment, seen, aliased)
  }
}

/// The constructors of a custom type that are in scope, or `None` when the type
/// is opaque and only a catch-all can cover it.
fn constructors(
  environment: types.Environment,
  seen: List(String),
  module_name: String,
  name: String,
  subject_parameters: List(types.Type),
) -> option.Option(List(Field)) {
  case seen_count(seen, name) >= mode_expansion_depth {
    True -> option.None
    False ->
      constructors_(environment, seen, module_name, name, subject_parameters)
  }
}

fn constructors_(
  environment: types.Environment,
  seen: List(String),
  module_name: String,
  name: String,
  subject_parameters: List(types.Type),
) -> option.Option(List(Field)) {
  let source = case module_name {
    "." -> environment.current_module
    other -> other
  }
  let definitions = case source == environment.current_module {
    True -> environment.definitions
    False -> {
      let from_namespace = fn(alias: String) {
        dict.get(environment.module_imports, alias)
        |> result.map(fn(namespace) {
          case namespace {
            types.NamespaceType(nested_defs, _) -> nested_defs
            _ -> dict.new()
          }
        })
      }
      case from_namespace(source) {
        Ok(nested_defs) -> nested_defs
        Error(_) ->
          // Namespaces are registered under their short alias (e.g. `order`
          // for `import gleam/order`), so resolve the full module name carried
          // by the custom type through the import mapping.
          from_namespace(types.module_access_name(environment, source))
          |> result.unwrap(environment.definitions)
      }
    }
  }
  // A definition is a variant constructor when its own return type is the
  // custom type; make this distinction by the presence of a variant index. A
  // plain function that merely returns the type (e.g. `map(x: T) -> T`) is not
  // a constructor, otherwise its parameters would pull the type into itself.
  let variant_index_of = fn(type_) {
    case type_ {
      types.CustomType(module, type_name, _, option.Some(index)) ->
        case
          type_name == name && { module == module_name || module == source }
        {
          True -> option.Some(index)
          False -> option.None
        }
      _ -> option.None
    }
  }
  let by_index =
    dict.fold(definitions, dict.new(), fn(fields, def_name, def_type) {
      let #(index, parameters, return_) = case def_type {
        types.CallableType(parameters, _, return_) -> #(
          variant_index_of(return_),
          parameters,
          return_,
        )
        types.GenericCallableType(parameters, _, return_, _) -> #(
          variant_index_of(return_),
          parameters,
          return_,
        )
        _ -> #(variant_index_of(def_type), [], def_type)
      }
      case index {
        option.Some(variant) -> {
          // The definition's field types mention the type's formal parameters;
          // substitute the subject's actual type arguments so e.g. an
          // `Option(CaCert)` subject splits `Some` with the payload mode of
          // `CaCert` rather than of the generic `a`.
          let substitutions = case return_ {
            types.CustomType(_, _, formal_params, _) ->
              list.zip(formal_params, subject_parameters)
              |> list.fold([], fn(acc, pair) {
                let #(formal, actual) = pair
                case formal {
                  types.GenericTypeVariable(parameter_name) -> [
                    #(parameter_name, actual),
                    ..acc
                  ]
                  _ -> acc
                }
              })
              |> dict.from_list
            _ -> dict.new()
          }
          dict.insert(
            fields,
            variant,
            Field(
              def_name,
              list.map(parameters, fn(param) {
                let param =
                  types.substitute_type_variables(param, substitutions)
                mode_of_guarded(environment, [name, ..seen], param)
              }),
            ),
          )
        }
        option.None -> fields
      }
    })
  let fields = by_index
  let count = case
    list.fold(dict.to_list(fields), -1, fn(max, pair) {
      let #(index, _field) = pair
      case index > max {
        True -> index
        False -> max
      }
    })
  {
    -1 -> 0
    max -> max + 1
  }
  case count {
    0 -> option.None
    _ ->
      option.Some(
        list.map(range(0, count), fn(index) {
          dict.get(fields, index)
          |> result.unwrap(Field("?", []))
        }),
      )
  }
}

/// Reduce a glance pattern against the mode of its subject into the fragments
/// exhaustiveness cares about.
fn reduce(mode: Mode, pattern: glance.Pattern) -> Pat {
  case pattern {
    glance.PatternVariable(_, _) | glance.PatternDiscard(_, _) -> Any
    glance.PatternAssignment(_, inner, _) -> reduce(mode, inner)
    glance.PatternInt(_, _)
    | glance.PatternFloat(_, _)
    | glance.PatternString(_, _)
    | glance.PatternConcatenate(_, _, _, _) -> Literal
    glance.PatternBitString(_, _) -> Literal
    glance.PatternTuple(_, elements) ->
      Constructor(0, zip_fields(fields_of(mode, 0), elements))
    glance.PatternList(_, elements, tail) -> reduce_list(mode, elements, tail)
    glance.PatternVariant(_, _module, name, arguments, _spread) -> {
      let index = index_of(existing_fields(mode), name)
      let sub =
        list.fold(arguments, [], fn(acc, field) {
          case field {
            glance.UnlabelledField(p) -> [p, ..acc]
            glance.LabelledField(_, _, p) -> [p, ..acc]
            glance.ShorthandField(_, _) -> acc
          }
        })
      Constructor(index, zip_fields(fields_of(mode, index), list.reverse(sub)))
    }
  }
}

/// The constructors of a Finite mode.
fn existing_fields(mode: Mode) -> List(Field) {
  case mode {
    Finite(fields) -> fields
    Infinite -> []
  }
}

/// The field modes of the constructor at `index` of a subject's mode.
fn fields_of(mode: Mode, index: Int) -> List(Mode) {
  case at(existing_fields(mode), index) {
    option.Some(field) -> field.modes
    option.None -> []
  }
}

/// The index of the first constructor with the given name, or 0 if absent.
fn index_of(fields: List(Field), name: String) -> Int {
  index_of_from(fields, name, 0)
}

fn index_of_from(fields: List(Field), name: String, index: Int) -> Int {
  case fields {
    [] -> 0
    [field, ..rest] ->
      case field.name == name {
        True -> index
        False -> index_of_from(rest, name, index + 1)
      }
  }
}

/// Reduce each pattern against its corresponding field mode.
fn zip_fields(modes: List(Mode), patterns: List(glance.Pattern)) -> List(Pat) {
  list.zip(modes, patterns)
  |> list.map(fn(pair) {
    let #(mode, pattern) = pair
    reduce(mode, pattern)
  })
}

/// Unpack a constructor argument into its inner pattern (nothing for a
/// shorthand field, which binds a fresh variable that never fails).
/// Reduce a list pattern `[elements .. tail]` against a list subject's mode.
fn reduce_list(
  mode: Mode,
  elements: List(glance.Pattern),
  tail: option.Option(glance.Pattern),
) -> Pat {
  case elements {
    [head, ..rest] -> {
      // The tail of a list is the same list, so its mode is the mode we were
      // given. The cons constructor only carries the element mode for the head.
      let cons = fields_of(mode, 0)
      let element_mode = at(cons, 0) |> option.unwrap(Infinite)
      Constructor(0, [
        reduce(element_mode, head),
        reduce_list(mode, rest, tail),
      ])
    }
    [] ->
      case tail {
        option.Some(whole) -> reduce(mode, whole)
        option.None -> Constructor(1, [])
      }
  }
}

/// Drop the `Any` checks from every row.
fn strip(rows: List(Row)) -> List(Row) {
  list.map(rows, fn(row) {
    Row(
      list.filter(row.checks, fn(check) {
        let #(_, pat) = check
        pat != Any
      }),
    )
  })
}

/// The `(id, mode)` pairs of the original subjects, ignoring the fresh ids
/// introduced for constructor fields during splitting.
fn missing_id_mode_pairs(
  modes: dict.Dict(Int, Mode),
  subject_count: Int,
) -> List(#(Int, Mode)) {
  dict.to_list(modes)
  |> list.filter(fn(pair) {
    let #(id, _mode) = pair
    id < subject_count
  })
}

/// Every value a mode can take, as missing patterns: the constructors of a
/// finite mode, or the `_` catch-all of an infinite one.
fn all_values(pairs: List(#(Int, Mode))) -> List(MissingPattern) {
  list.flatten(
    list.map(pairs, fn(pair) {
      let #(_id, mode) = pair
      case mode {
        Finite(fields) ->
          list.map(fields, fn(field) {
            ValueMissing(
              field.name,
              list.map(field.modes, fn(_) { AnyMissing }),
            )
          })
        Infinite -> [AnyMissing]
      }
    }),
  )
}

/// Run the decision procedure over the matrix.
fn compile(
  modes: dict.Dict(Int, Mode),
  rows: List(Row),
  next_id: Int,
) -> Outcome {
  let rows = strip(rows)
  case rows {
    // An empty matrix (no clauses at all) misses every possible value of the
    // subjects: each constructor of a finite subject, or the catch-all `_` of
    // an infinite one.
    [] -> Outcome(all_values(missing_id_mode_pairs(modes, next_id)), next_id)
    _ ->
      case list.any(rows, fn(row) { row.checks == [] }) {
        True -> Outcome([], next_id)
        False -> run_decision(modes, rows, next_id)
      }
  }
}

/// Split the current matrix on one subject.
fn run_decision(
  modes: dict.Dict(Int, Mode),
  rows: List(Row),
  next_id: Int,
) -> Outcome {
  let pivot = case rows {
    [Row([#(pivot, _), ..]), ..] -> pivot
    _ -> -1
  }
  let pivot_mode = dict.get(modes, pivot) |> result.unwrap(Infinite)
  let remainder = dict.delete(modes, pivot)
  case pivot_mode {
    Infinite -> {
      // Literals never cover an infinite type; only a row that matches the
      // subject unconditionally (with no check on it) can. Such rows still
      // carry their other-subject checks, so we keep them.
      let no_check =
        list.filter(rows, fn(row) { has_subject(row, pivot) == False })
      case no_check {
        [] -> Outcome([AnyMissing], next_id)
        _ -> compile(remainder, no_check, next_id)
      }
    }
    Finite(fields) -> compile_subject(fields, rows, remainder, pivot, next_id)
  }
}

/// Whether a row has a check on the given subject.
fn has_subject(row: Row, id: Int) -> Bool {
  list.any(row.checks, fn(check) {
    let #(check_id, _) = check
    check_id == id
  })
}

/// Split a Finite subject on each of its constructors.
fn compile_subject(
  fields: List(Field),
  rows: List(Row),
  remainder: dict.Dict(Int, Mode),
  pivot: Int,
  next_id: Int,
) -> Outcome {
  list.fold(fields, Outcome([], next_id), fn(acc, field) {
    let Outcome(missing, next) = acc
    let field_modes = field.modes
    let field_count = list.length(field_modes)
    let field_ids = range(next, next + field_count)
    let want_index = index_of(fields, field.name)
    let matches =
      list.fold(rows, [], fn(acc_rows, row) {
        case split_one(row, pivot, field_ids, want_index) {
          option.Some(new_row) -> [new_row, ..acc_rows]
          option.None -> acc_rows
        }
      })
    case matches {
      [] ->
        Outcome(
          list.append(missing, [
            ValueMissing(
              field.name,
              list.map(field_modes, fn(_) { AnyMissing }),
            ),
          ]),
          next,
        )
      _ -> {
        let sub_modes =
          dict.merge(
            remainder,
            dict.from_list(list.zip(field_ids, field_modes)),
          )
        let Outcome(sub_missing, next2) =
          compile(sub_modes, matches, next + field_count)
        // A partially covered single-argument constructor reports its missing
        // arguments wrapped in the constructor, e.g. `Ok(False)` for a covered
        // `Ok(True)`; multi-argument constructors keep the flattened leaves.
        let wrapped = case field_count == 1 {
          True -> list.map(sub_missing, fn(m) { ValueMissing(field.name, [m]) })
          False -> sub_missing
        }
        case wrapped {
          [] -> Outcome(missing, next2)
          _ -> Outcome(list.append(missing, wrapped), next2)
        }
      }
    }
  })
}

/// Whether a row constrains the given subject to a specific constructor.
fn split_one(
  row: Row,
  pivot: Int,
  field_ids: List(Int),
  want_index: Int,
) -> option.Option(Row) {
  let without =
    list.filter(row.checks, fn(check) {
      let #(check_id, _) = check
      check_id != pivot
    })
  let on_pivot =
    list.filter(row.checks, fn(check) {
      let #(check_id, _) = check
      check_id == pivot
    })
  case on_pivot {
    [] -> option.Some(Row(without))
    [#(_, Constructor(index, arguments))] ->
      case index == want_index {
        True ->
          option.Some(Row(list.append(without, list.zip(field_ids, arguments))))
        False -> option.None
      }
    _ -> option.None
  }
}
