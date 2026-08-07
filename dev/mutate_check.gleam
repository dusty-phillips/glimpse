import argv
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import shellout
import simplifile

/// Differential mutation harness for glimpse's typechecker.
///
/// We take a single source module and generate mutants by rewriting small
/// pieces of it. Each mutant is judged against the real compiler:
///
///  1. The REAL `gleam check` runs in the project checkout. If it rejects the
///     mutant (non-zero exit), that is ground truth: the mutant has a genuine
///     error that glimpse itself should also catch.
///  2. glimpse's `dev_check` runs against the same checkout. If glimpse
///     ACCEPTS a mutant the real compiler rejected, that is a FALSE NEGATIVE
///     bug in glimpse.
///
/// Mutants come from several *kinds*, each aimed at a different part of the
/// typechecker:
///   - `type`   : swap a signature annotation for an incompatible one, covering
///                primitives and parametric types (`List`, `Option`, `Result`)
///   - `bool`   : flip `True`/`False` literals (breaks pattern exhaustiveness)
///   - `binop`  : swap a binary operator for a type-incompatible one
///   - `label`  : rename a labelled argument / record field
///   - `tuple`  : index a tuple with an out-of-range `.N`
///   - `pattern`: swap an integer literal in a `case` pattern so it collides
///                with another clause (exhaustiveness for non-bool patterns)
///   - `variant`: swap `Ok`/`Error` constructors (Result dispatch)
///   - `import` : rename the module on an `import` line
///
/// Ground truth is always the real compiler, so any mutation that is not a real
/// error is simply not counted. This makes it safe to over-generate mutants.
///
/// Every mutant runs two subprocess compiles (`gleam check` plus, on
/// rejection, glimpse `dev_check`), which dominate the runtime. To overlap
/// them, the harness spawns a worker pool with `--jobs <n>` parallelism; each
/// worker checks against its own copy of the project so the compiles truly run
/// concurrently. The original project is left untouched.
///
/// Run as:
///   `gleam run -m dev/mutate_check -- --root <work_root> --src <src_rel> [--jobs <n>] [--kind <kind>] [--count]`
pub fn main() {
  let args = argv.load().arguments
  case parse_args(args) {
    Error(msg) -> io.println_error(msg)
    Ok(opts) -> run(opts)
  }
}

/// Everything the runner needs, threaded through worker hand-offs.
type Options =
  #(String, String, option.Option(String), Bool, Int)

fn parse_args(args: List(String)) -> Result(Options, String) {
  // parse recursively to allow any option order
  let parsed = parse_args_(args, 4, option.None, False)
  case parsed {
    Ok(v) -> Ok(v)
    Error(_) ->
      Error(
        "usage: run -m dev/mutate_check -- --root <root> --src <src> [--jobs <n>] [--kind <kind>] [--count]",
      )
  }
}

fn parse_args_(
  args: List(String),
  jobs: Int,
  kind: option.Option(String),
  count: Bool,
) -> Result(Options, String) {
  case args {
    ["--root", root, "--src", src, ..rest] ->
      parse_rest(rest, root, src, jobs, kind, count)
    _ -> Error("requires --root and --src")
  }
}

fn parse_rest(
  args: List(String),
  root: String,
  src: String,
  jobs: Int,
  kind: option.Option(String),
  count: Bool,
) -> Result(Options, String) {
  case args {
    [] -> Ok(#(root, src, kind, count, jobs))
    ["--count", ..rest] -> parse_rest(rest, root, src, jobs, kind, True)
    ["--jobs", n, ..rest] ->
      case int.parse(n) {
        Ok(j) -> parse_rest(rest, root, src, j, kind, count)
        Error(_) -> Error("invalid --jobs value")
      }
    ["--kind", k, ..rest] ->
      parse_rest(rest, root, src, jobs, option.Some(k), count)
    _ -> Error("unknown option")
  }
}

/// One mutant: a description of what changed and the fully rewritten source.
type Mutant =
  #(String, String)

fn run(opts: Options) {
  let #(root, src, kind, count, jobs) = opts
  let path = "/" <> string.join([root, src], "/")
  case simplifile.read(from: path) {
    Error(_) -> io.println_error("cannot read " <> path)

    Ok(original) -> {
      let mutants = mutate_file(original)
      let mutants = dedup(mutants)
      let mutants = case kind {
        option.None -> mutants
        option.Some(k) ->
          list.filter(mutants, fn(m) { string.starts_with(m.0, k) })
      }
      case count {
        True -> {
          io.println(
            string.inspect(list.length(mutants))
            <> " mutants (count only) in "
            <> src,
          )
          io.println(counts_by_kind(mutants))
        }
        False -> check_all(root, path, src, original, mutants, jobs)
      }
    }
  }
}

/// Check every mutant, `jobs` at a time. Each worker gets a private copy of
/// the project (with its generated files) so the subprocess compiles overlap.
fn check_all(
  root: String,
  path: String,
  src: String,
  original: String,
  mutants: List(Mutant),
  jobs: Int,
) {
  io.println(
    string.inspect(list.length(mutants))
    <> " mutants, "
    <> string.inspect(jobs)
    <> " jobs",
  )
  // Safety clamp: never more workers than mutants, never fewer than one.
  let workers = int.max(1, int.min(jobs, list.length(mutants)))
  let batches = split_into(mutants, workers)
  let subject = process.new_subject()
  let _ =
    list.index_map(batches, fn(batch, i) {
      let worker_root = worker_dir(root, i)
      // A previous run may have left a copy at this path; `cp -r` into an
      // existing directory would nest, so clear it first.
      let _ =
        shellout.command(
          run: "rm",
          with: ["-rf", worker_root],
          in: ".",
          opt: [],
        )
      let _ =
        shellout.command(
          run: "cp",
          with: ["-r", root, worker_root],
          in: ".",
          opt: [],
        )
      process.spawn(fn() {
        let results =
          list.map(batch, fn(mut) {
            check_one_worker(i, worker_root, src, original, mut)
          })
        process.send(subject, #(i, results))
      })
    })

  // Receive one batch of results per worker; order is irrelevant for reporting.
  let collected =
    indices(workers)
    |> list.fold([], fn(acc, _i) {
      let #(idx, results) = process.receive_forever(subject)
      [#(idx, results), ..acc]
    })
  let results = combine_results(collected, list.length(mutants))
  let false_negatives =
    list.filter(results, fn(r) { string.starts_with(r, "FALSE-NEG") })

  let _ = list.each(results, fn(r) { io.println(r) })

  // leave the source file restored to its original content
  write(path, original)
  io.println(
    "\n"
    <> string.inspect(list.length(false_negatives))
    <> "/"
    <> string.inspect(list.length(results))
    <> " FALSE NEGATIVES in "
    <> src,
  )
}

/// Give each `jobs` worker a roughly equal slice of the mutant list, preserving
/// document order within each slice.
fn split_into(mutants: List(Mutant), jobs: Int) -> List(List(Mutant)) {
  let size = ceiling_division(list.length(mutants), jobs)
  indices(jobs)
  |> list.map(fn(i) { list.take(list.drop(mutants, i * size), size) })
  // drop trailing empty slices from a few extra workers
  |> list.filter(fn(slice) { slice != [] })
}

/// The integers `[0, 1, ..., n - 1]` (there is no `list.range` in this
/// stdlib version).
fn indices(n: Int) -> List(Int) {
  indices_from(0, n, [])
}

fn indices_from(i: Int, n: Int, acc: List(Int)) -> List(Int) {
  case i >= n {
    True -> list.reverse(acc)
    False -> indices_from(i + 1, n, [i, ..acc])
  }
}

fn ceiling_division(a: Int, b: Int) -> Int {
  let quotient = int.divide(a, by: b) |> result.unwrap(0)
  case int.modulo(a, by: b) {
    Ok(0) -> quotient
    _ -> quotient + 1
  }
}

fn combine_results(
  collected: List(#(Int, List(String))),
  total: Int,
) -> List(String) {
  // order is irrelevant for a report; concatenate all worker results.
  let _ = total
  list.flatten(list.map(collected, fn(p) { p.1 }))
}

fn worker_dir(root: String, i: Int) -> String {
  root <> ".w" <> int.to_string(i)
}

/// Run one mutant in a worker: write the mutant into the worker's copy, run
/// the real and glimpse checks in *that* copy, and restore the worker's source.
fn check_one_worker(
  _worker_i: Int,
  worker_root: String,
  src: String,
  original: String,
  mut: Mutant,
) -> String {
  let path = "/" <> string.join([worker_root, src], "/")
  write(path, mut.1)
  let result = case real_check(worker_root) {
    Ok(_) -> "real-accepts :: " <> mut.0
    Error(_) ->
      case glimpse_check(worker_root) {
        True -> {
          let record = "FALSE-NEG :: " <> mut.0 <> "\n" <> mut.1 <> "\n\n"
          let _ =
            simplifile.append(
              to: "/tmp/mutcheck/falsenegs.txt",
              contents: record,
            )
          "FALSE-NEG :: " <> mut.0
        }
        False -> "ok :: " <> mut.0
      }
  }
  write(path, original)
  result
}

/// Tally how many mutants each kind contributed, for sizing runs.
fn counts_by_kind(mutants: List(Mutant)) -> String {
  let kinds = [
    "type ",
    "bool ",
    "binop ",
    "label ",
    "tuple ",
    "pattern ",
    "variant ",
    "import ",
  ]
  list.map(kinds, fn(kind) {
    let n = list.count(mutants, fn(m) { string.starts_with(m.0, kind) })
    kind <> string.inspect(n)
  })
  |> string.join(", ")
}

fn split_lines(source: String) -> List(String) {
  string.split(source, "\n")
}

fn fetch(lines: List(String), index: Int) -> String {
  list.index_map(lines, fn(line, i) { #(i, line) })
  |> list.filter(fn(p) { p.0 == index })
  |> list.map(fn(p) { p.1 })
  |> first_or("")
}

fn first_or(items: List(String), fallback: String) -> String {
  case items {
    [first, ..] -> first
    [] -> fallback
  }
}

/// Drop mutants that share the same rewritten source. Different kinds (or
/// different swap sites on the same line) can yield identical text; checking
/// the same text twice is wasted work.
fn dedup(mutants: List(Mutant)) -> List(Mutant) {
  dedup_into(mutants, [])
}

fn dedup_into(mutants: List(Mutant), acc: List(String)) -> List(Mutant) {
  case mutants {
    [] -> []
    [m, ..rest] ->
      case list.contains(acc, m.1) {
        True -> dedup_into(rest, acc)
        False -> [m, ..dedup_into(rest, [m.1, ..acc])]
      }
  }
}

fn replace_at(lines: List(String), index: Int, line: String) -> List(String) {
  list.index_map(lines, fn(original, i) {
    case i == index {
      True -> line
      False -> original
    }
  })
}

fn source_of(lines: List(String), index: Int, line: String) -> String {
  string.join(replace_at(lines, index, line), "\n")
}

/// Build a mutant by replacing `old` with `new` on line `index`. Only produces
/// a mutant if the line actually contains `old`.
fn swap_on_line(
  lines: List(String),
  index: Int,
  desc: String,
  old: String,
  new: String,
) -> List(Mutant) {
  case string.contains(fetch(lines, index), old) {
    False -> []
    True -> {
      let line = string.replace(fetch(lines, index), each: old, with: new)
      [#(desc, source_of(lines, index, line))]
    }
  }
}

/// Kind `type`: swap an `Int`/`String`/`Bool`/`Float` annotation for an
/// incompatible type, covering both parameters and return values. Also swaps
/// the type arguments of parametric types so generic unification is exercised.
fn type_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    swap_on_line(lines, idx, "type Int->String", "Int", "String")
    |> list.append(swap_on_line(lines, idx, "type Int->Bool", "Int", "Bool"))
    |> list.append(swap_on_line(lines, idx, "type Int->Float", "Int", "Float"))
    |> list.append(swap_on_line(lines, idx, "type String->Int", "String", "Int"))
    |> list.append(swap_on_line(
      lines,
      idx,
      "type String->Bool",
      "String",
      "Bool",
    ))
    |> list.append(swap_on_line(lines, idx, "type Bool->Int", "Bool", "Int"))
    |> list.append(swap_on_line(
      lines,
      idx,
      "type Bool->String",
      "Bool",
      "String",
    ))
    |> list.append(swap_on_line(lines, idx, "type Float->Int", "Float", "Int"))
    |> list.append(swap_on_line(
      lines,
      idx,
      "type Float->String",
      "Float",
      "String",
    ))
    |> list.append(swap_on_line(
      lines,
      idx,
      "type List(Int)->List(String)",
      "List(Int)",
      "List(String)",
    ))
    |> list.append(swap_on_line(
      lines,
      idx,
      "type List(String)->List(Int)",
      "List(String)",
      "List(Int)",
    ))
    |> list.append(swap_on_line(
      lines,
      idx,
      "type Option(Int)->Option(String)",
      "Option(Int)",
      "Option(String)",
    ))
    |> list.append(swap_on_line(
      lines,
      idx,
      "type Result(Int, String)->Result(String, Int)",
      "Result(Int, String)",
      "Result(String, Int)",
    ))
    |> list.append(swap_on_line(
      lines,
      idx,
      "type Dict(String, Int)->Dict(String, String)",
      "Dict(String, Int)",
      "Dict(String, String)",
    ))
  })
  |> list.flatten
}

/// Kind `bool`: flip each `True`/`False` literal. A `case` whose pattern
/// becomes a duplicate diverges coverage, so the real compiler reports the
/// case as inexhaustive.
fn bool_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    swap_on_line(lines, idx, "bool True->False", "True", "False")
    |> list.append(swap_on_line(lines, idx, "bool False->True", "False", "True"))
  })
  |> list.flatten
}

/// Kind `binop`: swap a binary operator for a type-incompatible one. Operators
/// are matched with surrounding spaces so `>`/`<` never collide with `->`
/// arrows or `|>` pipes.
fn binop_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    swap_on_line(lines, idx, "binop &&->||", " && ", " || ")
    |> list.append(swap_on_line(lines, idx, "binop ||->&&", " || ", " && "))
    |> list.append(swap_on_line(lines, idx, "binop ==->!=", " == ", " != "))
    |> list.append(swap_on_line(lines, idx, "binop !=->==", " != ", " == "))
    |> list.append(swap_on_line(lines, idx, "binop <->==", " < ", " == "))
    |> list.append(swap_on_line(lines, idx, "binop >->==", " > ", " == "))
    |> list.append(swap_on_line(lines, idx, "binop ==->&&", " == ", " && "))
    |> list.append(swap_on_line(lines, idx, "binop +-><>", " + ", " <> "))
    |> list.append(swap_on_line(lines, idx, "binop <>->+", " <> ", " + "))
  })
  |> list.flatten
}

/// Kind `label` and `field`: rename a labelled argument or record field
/// (`name:` or `.name`) to an unknown label.
fn label_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    name_spans(fetch(lines, idx))
    |> list.filter(fn(span) { span.2 == Label || span.2 == Field })
    |> list.map(fn(span) {
      let word =
        string.slice(fetch(lines, idx), at_index: span.0, length: span.1)
      let renamed = word <> "__zzz"
      swap_on_line(lines, idx, "label " <> word, word, renamed)
    })
    |> list.flatten
  })
  |> list.flatten
}

/// Kind `tuple`: index a tuple with an out-of-range `.N`.
fn tuple_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    swap_on_line(lines, idx, "tuple .0->.9", ".0", ".9")
    |> list.append(swap_on_line(lines, idx, "tuple .1->.9", ".1", ".9"))
  })
  |> list.flatten
}

/// Kind `pattern`: swap a small integer literal so that, when it lands in a
/// `case` pattern, it collides with another clause's pattern and the real
/// compiler rejects the clause as a duplicate or the case as inexhaustive.
/// The ground-truth filter means swaps that only hit expressions are ignored.
fn pattern_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    swap_on_line(lines, idx, "pattern 1->2", "1", "2")
    |> list.append(swap_on_line(lines, idx, "pattern 2->1", "2", "1"))
    |> list.append(swap_on_line(lines, idx, "pattern 0->1", "0", "1"))
  })
  |> list.flatten
}

/// Kind `variant`: swap a `Result` constructor between `Ok` and `Error`. In an
/// expression the argument type usually no longer matches; in a pattern it can
/// collide with another clause or break exhaustiveness.
fn variant_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    swap_on_line(lines, idx, "variant Ok->Error", "Ok(", "Error(")
    |> list.append(swap_on_line(
      lines,
      idx,
      "variant Error->Ok",
      "Error(",
      "Ok(",
    ))
  })
  |> list.flatten
}

/// Kind `import`: rename the module on an `import` line to a name that does
/// not exist, so import resolution must fail.
fn import_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    let line = fetch(lines, idx)
    case string.starts_with(line, "import ") {
      False -> []
      True -> {
        let path = import_path(string.drop_start(line, up_to: 7))
        case path == "" {
          True -> []
          False -> {
            let renamed = path <> "__zzz"
            [
              #(
                "import " <> path,
                string.replace(line, each: path, with: renamed),
              ),
            ]
          }
        }
      }
    }
  })
  |> list.flatten
}

/// The module path of an import (characters up to `.`, `{`, whitespace, or a
/// paren), e.g. `gleam/io` from `gleam/io` or `gleam/list.{type List}`.
fn import_path(rest: String) -> String {
  let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_"
  let first_stop =
    list.find(indices(string.length(rest)), fn(i) {
      let ch = string.slice(rest, at_index: i, length: 1)
      !string.contains(chars, ch)
    })
  case first_stop {
    Ok(i) -> string.slice(rest, at_index: 0, length: i)
    Error(_) -> rest
  }
}

/// Everything we can mutate in a file, one kind's mutants appended to the next.
fn mutate_file(source: String) -> List(Mutant) {
  let lines = split_lines(source)
  type_mutants(lines)
  |> list.append(bool_mutants(lines))
  |> list.append(binop_mutants(lines))
  |> list.append(label_mutants(lines))
  |> list.append(tuple_mutants(lines))
  |> list.append(pattern_mutants(lines))
  |> list.append(variant_mutants(lines))
  |> list.append(import_mutants(lines))
}

/// The role of an identifier in a line, inferred from the character that
/// precedes it.
type Kind {
  Label
  Field
  Other
}

type Span =
  #(Int, Int, Kind)

/// Find every identifier in `line`, recording its byte position and whether it
/// is a labelled argument / record field (followed by `:` after the name) or a
/// `.field` access (preceded by `.`).
fn name_spans(line: String) -> List(Span) {
  name_spans_from(line, 0, 0, option.None, [])
}

fn name_spans_from(
  line: String,
  index: Int,
  start: Int,
  prev: option.Option(String),
  acc: List(Span),
) -> List(Span) {
  case index < string.length(line) {
    False -> list.reverse(acc)
    True -> {
      let ch = string.slice(line, at_index: index, length: 1)
      let is_word = is_identifier_char(ch)
      case #(is_word, prev) {
        #(True, option.None) ->
          name_spans_from(line, index + 1, index, option.Some(ch), acc)
        #(True, option.Some(_)) ->
          name_spans_from(line, index + 1, start, option.Some(ch), acc)
        #(False, option.None) ->
          name_spans_from(line, index + 1, 0, option.Some(ch), acc)
        #(False, option.Some(_)) -> {
          let kind = classify(line, start, index, prev)
          name_spans_from(line, index + 1, 0, option.Some(ch), [kind, ..acc])
        }
      }
    }
  }
}

fn is_identifier_char(ch: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
    ch,
  )
}

/// Classify the just-finished word at [start, end). If the byte right before
/// it is `.` it is a field access; if the byte right after is `:` it is a
/// label.
fn classify(
  line: String,
  start: Int,
  end: Int,
  _prev: option.Option(String),
) -> Span {
  let before = byte_at(line, start - 1)
  let after = byte_at(line, end)
  let kind = case #(before, after) {
    #(".", _) -> Field
    #(_, ":") -> Label
    _ -> Other
  }
  #(start, end - start, kind)
}

fn byte_at(line: String, pos: Int) -> String {
  case pos < 0 || pos >= string.length(line) {
    True -> ""
    False -> string.slice(line, at_index: pos, length: 1)
  }
}

fn write(path: String, contents: String) {
  case simplifile.write(to: path, contents: contents) {
    _ -> Nil
  }
}

/// Run the real `gleam check`; Ok if it accepted the code, Error if rejected.
/// The project's `test/` directory is temporarily hidden so the real compiler
/// judges the same module set glimpse sees (glimpse only scans `src/` + deps).
fn real_check(root: String) -> Result(String, String) {
  let test_dir = "/" <> string.join([root, "test"], "/")
  let hide =
    shellout.command(
      run: "mv",
      with: [test_dir, test_dir <> ".bak"],
      in: "/",
      opt: [],
    )
  let check = shellout.command(run: "gleam", with: ["check"], in: root, opt: [])
  let _ =
    shellout.command(
      run: "mv",
      with: [test_dir <> ".bak", test_dir],
      in: "/",
      opt: [],
    )
  case hide {
    Error(_) -> Error("could not hide test dir")
    Ok(_) ->
      case check {
        Ok(out) -> Ok(out)
        Error(_) -> Error("real gleam rejected")
      }
  }
}

/// Whether glimpse's dev_check reports all modules typechecked.
fn glimpse_check(root: String) -> Bool {
  case
    shellout.command(
      run: "gleam",
      with: ["run", "-m", "dev_check", "--", "--typecheck", root],
      in: ".",
      opt: [],
    )
  {
    Ok(out) -> string.contains(out, "OK: all modules typechecked")
    Error(_) -> False
  }
}
