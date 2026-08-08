import argv
import dev_check
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
  // Default to more jobs than a single core's worth: workers are part I/O
  // bound (file copies and subprocess spawns), so parallelism above the core
  // count helps. Beyond ~1.5x cores the real `gleam check` subprocesses (each
  // already multithreaded) contend and throughput plateaus or degrades, so 16
  // is a safe default; tune with `--jobs`.
  let parsed = parse_args_(args, 16, option.None, False)
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
///
/// The worker copies are keyed only by the root path (`<root>.w<i>`), so two
/// concurrent invocations against the *same* root would share worker dirs and
/// overwrite each other's mutant files, corrupting results. Run sweeps
/// sequentially, one root at a time.
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
    indices(list.length(batches))
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
    "bitstring ",
    "literal ",
    "arg ",
    "lblarg ",
    "arity ",
    "negate ",
    "letpat ",
    "sigswap ",
    "pipe ",
    "casepat ",
    "clausepat ",
    "guard ",
    "typeparam ",
    "bitreorder ",
    "letswap ",
    "importfn ",
    "use ",
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
    |> list.append(swap_on_line(lines, idx, "binop <.-><", " <.", " < "))
    |> list.append(swap_on_line(lines, idx, "binop <-><.", " < ", " <. "))
    |> list.append(swap_on_line(lines, idx, "binop <=.-><=", " <=.", " <= "))
    |> list.append(swap_on_line(lines, idx, "binop <=-><=.", " <= ", " <=. "))
    |> list.append(swap_on_line(lines, idx, "binop >=.->>=", " >=.", " >= "))
    |> list.append(swap_on_line(lines, idx, "binop >=->>=.", " >= ", " >=. "))
    |> list.append(swap_on_line(lines, idx, "binop >.->>", " >.", " > "))
    |> list.append(swap_on_line(lines, idx, "binop >->>.", " > ", " >. "))
    |> list.append(swap_on_line(lines, idx, "binop +.->+", " +.", " + "))
    |> list.append(swap_on_line(lines, idx, "binop +->+.", " + ", " +. "))
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

/// Kind `tuple`: index a tuple with an out-of-range `.N`, or swap between the
/// two positions when the tuple's elements have different types.
fn tuple_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    swap_on_line(lines, idx, "tuple .0->.9", ".0", ".9")
    |> list.append(swap_on_line(lines, idx, "tuple .1->.9", ".1", ".9"))
    |> list.append(swap_on_line(lines, idx, "tuple .0->.1", ".0", ".1"))
    |> list.append(swap_on_line(lines, idx, "tuple .1->.0", ".1", ".0"))
  })
  |> list.flatten
}

/// Kind `arity`: give a two-argument call one argument too few or too many, so
/// the real compiler reports a wrong-arity error. The ground-truth filter keeps
/// mutations of variadic-ish or single-parameter functions out of the count.
fn arity_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    let line = fetch(lines, idx)
    case find_two_arg_call(line) {
      option.None -> []
      option.Some(#(
        _call_start,
        first_start,
        first_end,
        second_start,
        second_end,
      )) -> {
        let len = string.length(line)
        let second =
          string.slice(
            line,
            at_index: second_start,
            length: second_end - second_start,
          )
        // drop the second argument: `f(a, b)` -> `f(a)`
        let drop_second =
          string.slice(line, at_index: 0, length: first_end)
          <> string.slice(line, at_index: second_end, length: len - second_end)
        // drop the first argument: `f(a, b)` -> `f(b)`
        let drop_first =
          string.slice(line, at_index: 0, length: first_start)
          <> string.slice(
            line,
            at_index: second_start,
            length: len - second_start,
          )
        // duplicate the second argument: `f(a, b)` -> `f(a, b, b)`
        let dup_second =
          string.slice(line, at_index: 0, length: second_end)
          <> ", "
          <> second
          <> string.slice(line, at_index: second_end, length: len - second_end)
        [
          #("arity drop-second", source_of(lines, idx, drop_second)),
          #("arity drop-first", source_of(lines, idx, drop_first)),
          #("arity dup-second", source_of(lines, idx, dup_second)),
        ]
      }
    }
  })
  |> list.flatten
}

/// Kind `negate`: prepend a unary negation to an identifier. `-x` demands an
/// Int, `-.x` a Float, `!x` a Bool, so negating a value of the wrong type is a
/// real error. Only identifiers in argument position (right after `(` or `,`)
/// are mutated: there the negation stays parseable and lands on a value whose
/// type is constrained by a parameter. Type names, keywords, and
/// module/record accessors are skipped. `@external` and `@target` arguments
/// are also skipped: glimpse intentionally accepts targets beyond `js`/`erlang`,
/// and the target argument is not typechecked.
fn negate_mutants(lines: List(String)) -> List(Mutant) {
  let keywords = [
    "fn", "let", "pub", "import", "type", "case", "if", "else", "use", "as",
    "assert", "loop", "todo", "panic",
  ]
  let type_names = [
    "Int", "String", "Bool", "Float", "Nil", "True", "False", "List", "Result",
    "Option", "Dict", "Ok", "Error", "Some", "None",
  ]
  list.index_map(lines, fn(_line, idx) {
    let line = fetch(lines, idx)
    case
      string.starts_with(line, "@external")
      || string.starts_with(line, "@target")
    {
      True -> []
      False ->
        name_spans(line)
        |> list.filter(fn(span) { span.2 == Other })
        |> list.filter(fn(span) {
          let word = string.slice(line, at_index: span.0, length: span.1)
          let before = byte_at(line, span.0 - 1)
          let prev_prev = byte_at(line, span.0 - 2)
          let after_comma = before == " " && prev_prev == ","
          let in_arg_position = before == "(" || after_comma
          !list.contains(keywords, word)
          && !list.contains(type_names, word)
          && before != "."
          && before != "#"
          && before != ":"
          && in_arg_position
        })
        |> list.map(fn(span) {
          let word = string.slice(line, at_index: span.0, length: span.1)
          let prefix = fn(neg) {
            string.slice(line, at_index: 0, length: span.0)
            <> neg
            <> string.slice(
              line,
              at_index: span.0,
              length: string.length(line) - span.0,
            )
          }
          [
            #("negate -" <> word, source_of(lines, idx, prefix("-"))),
            #("negate -." <> word, source_of(lines, idx, prefix("-."))),
            #("negate !" <> word, source_of(lines, idx, prefix("!"))),
          ]
        })
        |> list.flatten
    }
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

/// Kind `bitstring`: swap a bit-string segment option so its value's type no
/// longer matches the forced family. A String/Float segment given an integer
/// size, or an Int segment given `:utf8`, is rejected by the real compiler.
/// (`:binary` is skipped: it is not a valid Gleam option at all and `glance`
/// collapses it to `:bytes`, so the typechecker cannot distinguish them.)
fn bitstring_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    swap_on_line(lines, idx, "bitstring utf8->8", ":utf8", ":8")
    |> list.append(swap_on_line(lines, idx, "bitstring 8->utf8", ":8", ":utf8"))
    |> list.append(swap_on_line(
      lines,
      idx,
      "bitstring binary->utf8",
      ":binary",
      ":utf8",
    ))
    |> list.append(swap_on_line(
      lines,
      idx,
      "bitstring utf8->binary",
      ":utf8",
      ":binary",
    ))
    |> list.append(swap_on_line(
      lines,
      idx,
      "bitstring float->8",
      ":float",
      ":8",
    ))
    |> list.append(swap_on_line(
      lines,
      idx,
      "bitstring bytes->utf8",
      ":bytes",
      ":utf8",
    ))
    |> list.append(swap_on_line(
      lines,
      idx,
      "bitstring utf8->bytes",
      ":utf8",
      ":bytes",
    ))
  })
  |> list.flatten
}

/// Kind `literal`: swap a literal for one of a different type, so a value used
/// where its type is pinned to another primitive is rejected.
fn literal_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    swap_on_line(lines, idx, "literal 1.5->1", "1.5", "1")
    |> list.append(swap_on_line(
      lines,
      idx,
      "literal 1.5->\"a\"",
      "1.5",
      "\"a\"",
    ))
    |> list.append(swap_on_line(lines, idx, "literal True->1", "True", "1"))
    |> list.append(swap_on_line(lines, idx, "literal False->0", "False", "0"))
    |> list.append(swap_on_line(lines, idx, "literal 0->False", "0", "False"))
    |> list.append(swap_on_line(lines, idx, "literal 1->True", "1", "True"))
    |> list.append(swap_on_line(lines, idx, "literal \"a\"->1", "\"a\"", "1"))
    |> list.append(swap_on_line(lines, idx, "literal 1->\"a\"", "1", "\"a\""))
  })
  |> list.flatten
}

/// Kind `arg`: swap the two arguments of a two-argument call when both are
/// simple identifiers or literals, so a call whose arguments have different
/// types is rejected.
fn arg_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    swap_args_in_line(lines, idx, fetch(lines, idx))
  })
  |> list.flatten
}

/// Produce a mutant swapping the first two simple arguments of the first
/// two-argument call on `line`.
fn swap_args_in_line(
  lines: List(String),
  index: Int,
  line: String,
) -> List(Mutant) {
  case find_two_arg_call(line) {
    option.None -> []
    option.Some(#(call_start, first_start, first_end, second_start, second_end)) -> {
      let first =
        string.slice(
          line,
          at_index: first_start,
          length: first_end - first_start,
        )
      let second =
        string.slice(
          line,
          at_index: second_start,
          length: second_end - second_start,
        )
      let swapped =
        string.slice(line, at_index: 0, length: first_start)
        <> second
        <> string.slice(
          line,
          at_index: first_end,
          length: second_start - first_end,
        )
        <> first
        <> string.slice(
          line,
          at_index: second_end,
          length: string.length(line) - second_end,
        )
      case first == second {
        True -> []
        False -> [#("arg swap", source_of(lines, index, swapped))]
      }
    }
  }
}

fn is_simple_arg_char(ch: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.\"",
    ch,
  )
}

/// Kind `letpat`: swap the two elements of a tuple destructure pattern
/// (`let #(a, b) = ...`), so the pattern binds each name to the other's type.
/// If the tuple's elements differ in type, later uses of the names diverge from
/// what the source intends and the real compiler rejects.
fn letpat_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    let line = fetch(lines, idx)
    case find_tuple_pattern(line) {
      option.None -> []
      option.Some(#(first_start, first_end, second_start, second_end)) -> {
        let first =
          string.slice(
            line,
            at_index: first_start,
            length: first_end - first_start,
          )
        let second =
          string.slice(
            line,
            at_index: second_start,
            length: second_end - second_start,
          )
        let swapped =
          string.slice(line, at_index: 0, length: first_start)
          <> second
          <> string.slice(
            line,
            at_index: first_end,
            length: second_start - first_end,
          )
          <> first
          <> string.slice(
            line,
            at_index: second_end,
            length: string.length(line) - second_end,
          )
        case first == second {
          True -> []
          False -> [#("letpat swap", source_of(lines, idx, swapped))]
        }
      }
    }
  })
  |> list.flatten
}

/// Find a `#(a, b)` pattern inside a `let` binding on `line`. Returns the byte
/// offsets of the two pattern names.
fn find_tuple_pattern(line: String) -> option.Option(#(Int, Int, Int, Int)) {
  case string.contains(line, "=") && string.contains(line, "#(") {
    False -> option.None
    True -> find_tuple_pattern_from(line, 0, option.None)
  }
}

fn find_tuple_pattern_from(
  line: String,
  index: Int,
  acc: option.Option(#(Int, Int, Int, Int)),
) -> option.Option(#(Int, Int, Int, Int)) {
  case index >= string.length(line) {
    True -> acc
    False -> {
      let ch = string.slice(line, at_index: index, length: 1)
      case ch {
        "#" -> {
          case read_call_args(line, index + 1) {
            option.Some(#(
              _call_start,
              first_start,
              first_end,
              second_start,
              second_end,
            )) ->
              option.Some(#(first_start, first_end, second_start, second_end))
            option.None -> find_tuple_pattern_from(line, index + 1, acc)
          }
        }
        _ -> find_tuple_pattern_from(line, index + 1, acc)
      }
    }
  }
}

/// Scan `line` for a call `name(tok, tok)` where both arguments are runs of
/// simple characters. Returns the byte offsets of the call and both arguments.
fn find_two_arg_call(
  line: String,
) -> option.Option(#(Int, Int, Int, Int, Int)) {
  find_two_arg_call_from(line, 0, option.None)
}

fn find_two_arg_call_from(
  line: String,
  index: Int,
  acc: option.Option(#(Int, Int, Int, Int, Int)),
) -> option.Option(#(Int, Int, Int, Int, Int)) {
  case index >= string.length(line) {
    True -> acc
    False -> {
      let ch = string.slice(line, at_index: index, length: 1)
      case ch {
        "(" -> {
          // Skip if this paren belongs to a record type/annotation like
          // `fn(a, b)` or `Tuple(a, b)`: a type context. We cannot tell
          // reliably, so only accept if the two args are simple tokens.
          case read_call_args(line, index) {
            option.Some(span) -> option.Some(span)
            option.None -> find_two_arg_call_from(line, index + 1, acc)
          }
        }
        _ -> find_two_arg_call_from(line, index + 1, acc)
      }
    }
  }
}

/// Given `line` and the index of a `(`, try to read `tok, tok)`. Returns
/// `#(call_start, first_start, first_end, second_start, second_end)` if the
/// paren contains exactly two comma-separated simple tokens followed by `)`.
fn read_call_args(
  line: String,
  open_index: Int,
) -> option.Option(#(Int, Int, Int, Int, Int)) {
  let after = open_index + 1
  let first_start = first_simple_start(line, after)
  case first_start {
    option.None -> option.None
    option.Some(first_start) -> {
      let first_end = simple_token_end(line, first_start)
      case string.slice(line, at_index: first_end, length: 1) {
        "," ->
          case skip_spaces(line, first_end + 1) {
            option.Some(second_start) -> {
              let second_end = simple_token_end(line, second_start)
              case string.slice(line, at_index: second_end, length: 1) {
                ")" ->
                  option.Some(#(
                    open_index,
                    first_start,
                    first_end,
                    second_start,
                    second_end,
                  ))
                _ -> option.None
              }
            }
            option.None -> option.None
          }
        _ -> option.None
      }
    }
  }
}

fn first_simple_start(line: String, from: Int) -> option.Option(Int) {
  case from >= string.length(line) {
    True -> option.None
    False ->
      case is_simple_arg_char(string.slice(line, at_index: from, length: 1)) {
        True -> option.Some(from)
        False -> first_simple_start(line, from + 1)
      }
  }
}

fn simple_token_end(line: String, from: Int) -> Int {
  case from >= string.length(line) {
    True -> from
    False ->
      case is_simple_arg_char(string.slice(line, at_index: from, length: 1)) {
        True -> simple_token_end(line, from + 1)
        False -> from
      }
  }
}

fn skip_spaces(line: String, from: Int) -> option.Option(Int) {
  case from >= string.length(line) {
    True -> option.None
    False ->
      case string.slice(line, at_index: from, length: 1) {
        " " -> skip_spaces(line, from + 1)
        _ -> option.Some(from)
      }
  }
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

/// Kind `sigswap`: swap the type annotations of two adjacent parameters in a
/// function signature, e.g. `fn go(a: Int, b: String)` becomes
/// `fn go(a: String, b: Int)`. The body still uses each parameter name as
/// before, so any use that relied on the original type is now rejected.
fn sigswap_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    let line = fetch(lines, idx)
    case find_param_annotations(line) {
      option.None -> []
      option.Some(#(first_start, first_end, second_start, second_end)) -> {
        let first_type =
          string.slice(
            line,
            at_index: first_start,
            length: first_end - first_start,
          )
        let second_type =
          string.slice(
            line,
            at_index: second_start,
            length: second_end - second_start,
          )
        let swapped =
          string.slice(line, at_index: 0, length: first_start)
          <> second_type
          <> string.slice(
            line,
            at_index: first_end,
            length: second_start - first_end,
          )
          <> first_type
          <> string.slice(
            line,
            at_index: second_end,
            length: string.length(line) - second_end,
          )
        case first_type == second_type {
          True -> []
          False -> [#("sigswap swap", source_of(lines, idx, swapped))]
        }
      }
    }
  })
  |> list.flatten
}

/// Find two `name: Type` parameters on a signature line where both types are
/// simple tokens (`Int`, `String`, `Bool`, `Float`, or `List(...)`). Returns
/// the byte offsets of the two type tokens.
fn find_param_annotations(
  line: String,
) -> option.Option(#(Int, Int, Int, Int)) {
  case string.contains(line, "(") && string.contains(line, ":") {
    False -> option.None
    True -> {
      // Collect every `: Type` annotation's type-token offsets.
      let annotations = collect_annotations(line, 0, [])
      case annotations {
        [first, second, ..] ->
          option.Some(#(first.0, first.1, second.0, second.1))
        _ -> option.None
      }
    }
  }
}

fn collect_annotations(
  line: String,
  index: Int,
  acc: List(#(Int, Int)),
) -> List(#(Int, Int)) {
  case index >= string.length(line) {
    True -> list.reverse(acc)
    False -> {
      let ch = string.slice(line, at_index: index, length: 1)
      case ch {
        ":" -> {
          case skip_spaces(line, index + 1) {
            option.Some(type_start) -> {
              let type_end = simple_token_end(line, type_start)
              let type_token =
                string.slice(
                  line,
                  at_index: type_start,
                  length: type_end - type_start,
                )
              // Only primitive types: swapping `List(Int)` would truncate the
              // token at the `(` and produce a malformed annotation.
              case
                list.contains(
                  ["Int", "String", "Bool", "Float", "Nil"],
                  type_token,
                )
              {
                True ->
                  collect_annotations(line, index + 1, [
                    #(type_start, type_end),
                    ..acc
                  ])
                False -> collect_annotations(line, index + 1, acc)
              }
            }
            option.None -> collect_annotations(line, index + 1, acc)
          }
        }
        _ -> collect_annotations(line, index + 1, acc)
      }
    }
  }
}

/// Kind `casepat`: mutate multi-subject `case` expressions. Swapping the two
/// subjects (`case a, b` -> `case b, a`) makes each subject match the wrong
/// pattern; dropping the second subject breaks pattern-count alignment. Either
/// way the real compiler rejects the clause.
/// Kind `letswap`: swap the right-hand sides of two adjacent `let` bindings
/// whose values are simple tokens, e.g.
/// `let a = x` / `let b = y` becomes `let a = y` / `let b = x`. If the two
/// values have different types, later uses of the names diverge and the real
/// compiler rejects.
fn letswap_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    case find_let_rhs(fetch(lines, idx)) {
      option.None -> []
      option.Some(rhs) ->
        case find_let_rhs(fetch(lines, idx + 1)) {
          option.None -> []
          option.Some(next_rhs) -> {
            let #(start_a, end_a) = rhs
            let #(start_b, end_b) = next_rhs
            let line_a = fetch(lines, idx)
            let line_b = fetch(lines, idx + 1)
            let first =
              string.slice(line_a, at_index: start_a, length: end_a - start_a)
            let second =
              string.slice(line_b, at_index: start_b, length: end_b - start_b)
            case first == second {
              True -> []
              False -> {
                let new_a =
                  string.slice(line_a, at_index: 0, length: start_a)
                  <> second
                  <> string.slice(
                    line_a,
                    at_index: end_a,
                    length: string.length(line_a) - end_a,
                  )
                let new_b =
                  string.slice(line_b, at_index: 0, length: start_b)
                  <> first
                  <> string.slice(
                    line_b,
                    at_index: end_b,
                    length: string.length(line_b) - end_b,
                  )
                let new_lines =
                  replace_at(lines, idx, new_a)
                  |> replace_at(idx + 1, new_b)
                [#("letswap swap", string.join(new_lines, "\n"))]
              }
            }
          }
        }
    }
  })
  |> list.flatten
}

/// Find `let name = simple_token` on a line. Returns the offsets of the value
/// token.
fn find_let_rhs(line: String) -> option.Option(#(Int, Int)) {
  case string.contains(line, "let ") && string.contains(line, " = ") {
    False -> option.None
    True -> {
      let equals = find_char(line, "=")
      case equals {
        option.None -> option.None
        option.Some(eq) -> {
          case skip_spaces(line, eq + 1) {
            option.Some(value_start) -> {
              let value_end = simple_token_end(line, value_start)
              case value_end == value_start {
                True -> option.None
                False -> option.Some(#(value_start, value_end))
              }
            }
            option.None -> option.None
          }
        }
      }
    }
  }
}

fn find_char(line: String, target: String) -> option.Option(Int) {
  find_char_from(line, 0, target)
}

fn find_char_from(
  line: String,
  index: Int,
  target: String,
) -> option.Option(Int) {
  case index >= string.length(line) {
    True -> option.None
    False ->
      case string.slice(line, at_index: index, length: 1) == target {
        True -> option.Some(index)
        False -> find_char_from(line, index + 1, target)
      }
  }
}

/// Kind `clausepat`: swap the patterns of two adjacent case clauses
/// (`Pat1 -> body1` / `Pat2 -> body2` becomes `Pat2 -> body1` /
/// `Pat1 -> body2`). If the two patterns bind different types of variables,
/// each body now sees the other's bindings and the real compiler rejects.
fn clausepat_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    case find_clause_pattern(fetch(lines, idx)) {
      option.None -> []
      option.Some(pat_a) ->
        case find_clause_pattern(fetch(lines, idx + 1)) {
          option.None -> []
          option.Some(pat_b) -> {
            let #(start_a, end_a) = pat_a
            let #(start_b, end_b) = pat_b
            let line_a = fetch(lines, idx)
            let line_b = fetch(lines, idx + 1)
            let pattern_a =
              string.slice(line_a, at_index: start_a, length: end_a - start_a)
            let pattern_b =
              string.slice(line_b, at_index: start_b, length: end_b - start_b)
            case pattern_a == pattern_b {
              True -> []
              False -> {
                let new_a =
                  string.slice(line_a, at_index: 0, length: start_a)
                  <> pattern_b
                  <> string.slice(
                    line_a,
                    at_index: end_a,
                    length: string.length(line_a) - end_a,
                  )
                let new_b =
                  string.slice(line_b, at_index: 0, length: start_b)
                  <> pattern_a
                  <> string.slice(
                    line_b,
                    at_index: end_b,
                    length: string.length(line_b) - end_b,
                  )
                let new_lines =
                  replace_at(lines, idx, new_a)
                  |> replace_at(idx + 1, new_b)
                [#("clausepat swap", string.join(new_lines, "\n"))]
              }
            }
          }
        }
    }
  })
  |> list.flatten
}

/// Find the pattern in a `pattern -> body` clause line. Returns the offsets of
/// the pattern (the text before ` -> `, trimmed).
fn find_clause_pattern(line: String) -> option.Option(#(Int, Int)) {
  case string.contains(line, " -> ") {
    False -> option.None
    True -> {
      let trimmed = string.trim(line)
      let indent = string.length(line) - string.length(trimmed)
      case string.split_once(trimmed, " -> ") {
        Error(_) -> option.None
        Ok(#(pattern, _body)) -> {
          let pattern_len = string.length(pattern)
          option.Some(#(indent, indent + pattern_len))
        }
      }
    }
  }
}

/// Kind `use`: rename the target of a `use` statement (`use x <- Foo(...)`
/// -> `use x <- Foo__zzz(...)`), so the use-expression target must resolve.
/// Exercises the `use` desugaring path in the typechecker.
fn use_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    let line = fetch(lines, idx)
    case find_use_target(line) {
      option.None -> []
      option.Some(#(start, end)) -> {
        let target = string.slice(line, at_index: start, length: end - start)
        let renamed = target <> "__zzz"
        let mutated =
          string.slice(line, at_index: 0, length: start)
          <> renamed
          <> string.slice(
            line,
            at_index: end,
            length: string.length(line) - end,
          )
        [#("use rename", source_of(lines, idx, mutated))]
      }
    }
  })
  |> list.flatten
}

/// Find the target function name of a `use` statement (`use x <- Foo`). Returns
/// the offsets of the target token.
fn find_use_target(line: String) -> option.Option(#(Int, Int)) {
  case string.contains(line, "use ") && string.contains(line, " <- ") {
    False -> option.None
    True ->
      find_use_arrow(line, 0)
      |> option.then(fn(arrow) {
        case skip_spaces(line, arrow + 2) {
          option.Some(target_start) -> {
            let target_end = simple_token_end(line, target_start)
            case target_end == target_start {
              True -> option.None
              False -> option.Some(#(target_start, target_end))
            }
          }
          option.None -> option.None
        }
      })
  }
}

fn find_use_arrow(line: String, index: Int) -> option.Option(Int) {
  case index + 1 >= string.length(line) {
    True -> option.None
    False ->
      case string.slice(line, at_index: index, length: 2) == "<-" {
        True -> option.Some(index)
        False -> find_use_arrow(line, index + 1)
      }
  }
}

/// Kind `lblarg`: swap the values of two labeled arguments in a call
/// (`f(a: x, b: y)` -> `f(a: y, b: x)`). If the two values have different types
/// the real compiler rejects. Complements the `arg` kind, which only matches
/// unlabeled two-argument calls.
fn lblarg_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    let line = fetch(lines, idx)
    case find_two_labeled_values(line) {
      option.None -> []
      option.Some(#(first_start, first_end, second_start, second_end)) -> {
        let first =
          string.slice(
            line,
            at_index: first_start,
            length: first_end - first_start,
          )
        let second =
          string.slice(
            line,
            at_index: second_start,
            length: second_end - second_start,
          )
        let swapped =
          string.slice(line, at_index: 0, length: first_start)
          <> second
          <> string.slice(
            line,
            at_index: first_end,
            length: second_start - first_end,
          )
          <> first
          <> string.slice(
            line,
            at_index: second_end,
            length: string.length(line) - second_end,
          )
        case first == second {
          True -> []
          False -> [#("lblarg swap", source_of(lines, idx, swapped))]
        }
      }
    }
  })
  |> list.flatten
}

/// Find two labeled argument values in a call: `label: token, label: token`.
/// Returns the offsets of the two value tokens.
fn find_two_labeled_values(
  line: String,
) -> option.Option(#(Int, Int, Int, Int)) {
  case string.contains(line, ": ") && string.contains(line, ", ") {
    False -> option.None
    True -> {
      // scan for `label: value, label: value`
      case find_label_value(line, 0) {
        option.None -> option.None
        option.Some(#(first_start, first_end, next)) ->
          case find_label_value(line, next) {
            option.None -> option.None
            option.Some(#(second_start, second_end, _next)) ->
              option.Some(#(first_start, first_end, second_start, second_end))
          }
      }
    }
  }
}

/// Find `label: value` in `line` starting at `from`. Returns the offsets of the
/// value token and the position after it (to continue scanning).
fn find_label_value(
  line: String,
  from: Int,
) -> option.Option(#(Int, Int, Int)) {
  case find_substring_from(line, from, ":") {
    option.None -> option.None
    option.Some(colon) -> {
      case skip_spaces(line, colon + 1) {
        option.None -> option.None
        option.Some(value_start) -> {
          let value_end = simple_token_end(line, value_start)
          case value_end == value_start {
            True -> option.None
            False -> option.Some(#(value_start, value_end, value_end))
          }
        }
      }
    }
  }
}

/// Kind `guard`: swap the two operands of a guard comparison in a case clause
/// (`x if a < b -> ...` becomes `x if b < a -> ...`). When the two operands
/// have different types, the real compiler rejects the swapped guard.
fn guard_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    let line = fetch(lines, idx)
    case find_guard_comparison(line) {
      option.None -> []
      option.Some(#(
        op_start,
        op_end,
        first_start,
        first_end,
        second_start,
        second_end,
      )) -> {
        let first =
          string.slice(
            line,
            at_index: first_start,
            length: first_end - first_start,
          )
        let second =
          string.slice(
            line,
            at_index: second_start,
            length: second_end - second_start,
          )
        let swapped =
          string.slice(line, at_index: 0, length: first_start)
          <> second
          <> string.slice(
            line,
            at_index: first_end,
            length: second_start - first_end,
          )
          <> first
          <> string.slice(
            line,
            at_index: second_end,
            length: string.length(line) - second_end,
          )
        let _ = op_start
        let _ = op_end
        case first == second {
          True -> []
          False -> [#("guard swap", source_of(lines, idx, swapped))]
        }
      }
    }
  })
  |> list.flatten
}

/// Find `if a OP b` in a case-clause guard where both operands are simple
/// tokens. Returns the offsets of the operator and both operands.
fn find_guard_comparison(
  line: String,
) -> option.Option(#(Int, Int, Int, Int, Int, Int)) {
  case string.contains(line, " if ") {
    False -> option.None
    True -> {
      let operators = [" == ", " != ", " < ", " > ", " <= ", " >= "]
      find_guard_operator(line, operators)
    }
  }
}

fn find_guard_operator(
  line: String,
  operators: List(String),
) -> option.Option(#(Int, Int, Int, Int, Int, Int)) {
  case operators {
    [] -> option.None
    [op, ..rest] ->
      case find_substring(line, op) {
        option.None -> find_guard_operator(line, rest)
        option.Some(op_index) -> {
          let op_end = op_index + string.length(op)
          case find_token_before(line, op_index) {
            option.None -> find_guard_operator(line, rest)
            option.Some(#(first_start, first_end)) ->
              case find_token_after(line, op_end) {
                option.None -> find_guard_operator(line, rest)
                option.Some(#(second_start, second_end)) ->
                  option.Some(#(
                    op_index,
                    op_end,
                    first_start,
                    first_end,
                    second_start,
                    second_end,
                  ))
              }
          }
        }
      }
  }
}

fn find_token_after(line: String, from: Int) -> option.Option(#(Int, Int)) {
  case first_simple_start(line, from) {
    option.None -> option.None
    option.Some(start) -> {
      let end = simple_token_end(line, start)
      case end == start {
        True -> option.None
        False -> option.Some(#(start, end))
      }
    }
  }
}

fn find_substring(line: String, target: String) -> option.Option(Int) {
  find_substring_from(line, 0, target)
}

fn find_substring_from(
  line: String,
  index: Int,
  target: String,
) -> option.Option(Int) {
  case index + string.length(target) > string.length(line) {
    True -> option.None
    False ->
      case
        string.slice(line, at_index: index, length: string.length(target))
        == target
      {
        True -> option.Some(index)
        False -> find_substring_from(line, index + 1, target)
      }
  }
}

fn casepat_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    let line = fetch(lines, idx)
    case find_two_case_subjects(line) {
      option.None -> []
      option.Some(#(first_start, first_end, second_start, second_end)) -> {
        let first =
          string.slice(
            line,
            at_index: first_start,
            length: first_end - first_start,
          )
        let second =
          string.slice(
            line,
            at_index: second_start,
            length: second_end - second_start,
          )
        let swapped =
          string.slice(line, at_index: 0, length: first_start)
          <> second
          <> string.slice(
            line,
            at_index: first_end,
            length: second_start - first_end,
          )
          <> first
          <> string.slice(
            line,
            at_index: second_end,
            length: string.length(line) - second_end,
          )
        let dropped =
          string.slice(line, at_index: 0, length: first_end)
          <> string.slice(
            line,
            at_index: second_end,
            length: string.length(line) - second_end,
          )
        case first == second {
          True -> [#("casepat drop-subject", source_of(lines, idx, dropped))]
          False -> [
            #("casepat swap-subjects", source_of(lines, idx, swapped)),
            #("casepat drop-subject", source_of(lines, idx, dropped)),
          ]
        }
      }
    }
  })
  |> list.flatten
}

/// Find `case a, b {` on `line` where both subjects are simple tokens. Returns
/// the byte offsets of the two subject tokens.
fn find_two_case_subjects(
  line: String,
) -> option.Option(#(Int, Int, Int, Int)) {
  case string.starts_with(string.trim(line), "case ") {
    False -> option.None
    True -> {
      // offset of "case " within the line
      let case_offset =
        string.length(line) - string.length(string.trim(line)) + 5
      // first subject: first simple token after "case "
      case first_simple_start(line, case_offset) {
        option.None -> option.None
        option.Some(first_start) -> {
          let first_end = simple_token_end(line, first_start)
          // expect ", " then second subject
          case skip_spaces(line, first_end + 1) {
            option.Some(second_start) -> {
              let second_end = simple_token_end(line, second_start)
              option.Some(#(first_start, first_end, second_start, second_end))
            }
            option.None -> option.None
          }
        }
      }
    }
  }
}

/// Kind `typeparam`: swap the two type parameters in a custom type definition
/// (`type Foo(a, b)` -> `type Foo(b, a)`). Any use or annotation of `Foo(x, y)`
/// that relied on the original parameter order now mismatches when the two
/// parameter types differ.
fn typeparam_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    let line = fetch(lines, idx)
    case find_type_params(line) {
      option.None -> []
      option.Some(#(first_start, first_end, second_start, second_end)) -> {
        let first =
          string.slice(
            line,
            at_index: first_start,
            length: first_end - first_start,
          )
        let second =
          string.slice(
            line,
            at_index: second_start,
            length: second_end - second_start,
          )
        let swapped =
          string.slice(line, at_index: 0, length: first_start)
          <> second
          <> string.slice(
            line,
            at_index: first_end,
            length: second_start - first_end,
          )
          <> first
          <> string.slice(
            line,
            at_index: second_end,
            length: string.length(line) - second_end,
          )
        case first == second {
          True -> []
          False -> [#("typeparam swap", source_of(lines, idx, swapped))]
        }
      }
    }
  })
  |> list.flatten
}

/// Find a `type Name(a, b)` (or `pub type Name(a, b)`) declaration with two
/// single-letter type parameters. Returns the offsets of the two parameters.
fn find_type_params(line: String) -> option.Option(#(Int, Int, Int, Int)) {
  let trimmed = string.trim(line)
  let is_type = string.starts_with(trimmed, "type ")
  let is_pub_type = string.starts_with(trimmed, "pub type ")
  case is_type || is_pub_type {
    False -> option.None
    True -> {
      // skip the "type " or "pub type " prefix and the name, find the "("
      let base_offset = string.length(line) - string.length(trimmed)
      let prefix_len = case is_pub_type {
        True -> 9
        False -> 5
      }
      case find_first_paren_after(line, base_offset + prefix_len) {
        option.Some(paren_index) -> read_two_params(line, paren_index)
        option.None -> option.None
      }
    }
  }
}

/// Read `a, b)` after a `(` where both are simple tokens (parameter names may
/// be multi-letter, e.g. `Dict(key, value)`).
fn read_two_params(
  line: String,
  open_index: Int,
) -> option.Option(#(Int, Int, Int, Int)) {
  case first_simple_start(line, open_index + 1) {
    option.None -> option.None
    option.Some(first_start) -> {
      let first_end = simple_token_end(line, first_start)
      case string.slice(line, at_index: first_end, length: 1) {
        "," ->
          case skip_spaces(line, first_end + 1) {
            option.Some(second_start) -> {
              let second_end = simple_token_end(line, second_start)
              case string.slice(line, at_index: second_end, length: 1) {
                ")" ->
                  option.Some(#(
                    first_start,
                    first_end,
                    second_start,
                    second_end,
                  ))
                _ -> option.None
              }
            }
            option.None -> option.None
          }
        _ -> option.None
      }
    }
  }
}

/// Kind `bitreorder`: swap the two segments of a bit-string literal/pattern
/// (`<<a, b>>` -> `<<b, a>>`). If the two segments carry different types
/// (e.g. an Int and a String utf segment) the real compiler rejects the swap.
fn bitreorder_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    let line = fetch(lines, idx)
    case find_two_segments(line) {
      option.None -> []
      option.Some(#(first_start, first_end, second_start, second_end)) -> {
        let first =
          string.slice(
            line,
            at_index: first_start,
            length: first_end - first_start,
          )
        let second =
          string.slice(
            line,
            at_index: second_start,
            length: second_end - second_start,
          )
        let swapped =
          string.slice(line, at_index: 0, length: first_start)
          <> second
          <> string.slice(
            line,
            at_index: first_end,
            length: second_start - first_end,
          )
          <> first
          <> string.slice(
            line,
            at_index: second_end,
            length: string.length(line) - second_end,
          )
        case first == second {
          True -> []
          False -> [#("bitreorder swap", source_of(lines, idx, swapped))]
        }
      }
    }
  })
  |> list.flatten
}

/// Find a `<<a, b>>` with exactly two comma-separated simple segments. Returns
/// the offsets of the two segments.
fn find_two_segments(line: String) -> option.Option(#(Int, Int, Int, Int)) {
  case string.contains(line, "<<") && string.contains(line, ">>") {
    False -> option.None
    True -> {
      case find_double_less(line, 0) {
        option.None -> option.None
        option.Some(open_index) ->
          case find_segment_pair(line, open_index + 2) {
            option.Some(offsets) -> option.Some(offsets)
            option.None -> option.None
          }
      }
    }
  }
}

fn find_double_less(line: String, index: Int) -> option.Option(Int) {
  case index + 1 >= string.length(line) {
    True -> option.None
    False ->
      case string.slice(line, at_index: index, length: 2) == "<<" {
        True -> option.Some(index)
        False -> find_double_less(line, index + 1)
      }
  }
}

/// Read `tok, tok >>` after a `<<` where both segments are runs of characters
/// up to the separating `,` or the closing `>>` (a segment includes options
/// like `a:8` or `x:8/utf8`).
fn find_segment_pair(
  line: String,
  from: Int,
) -> option.Option(#(Int, Int, Int, Int)) {
  case first_simple_start(line, from) {
    option.None -> option.None
    option.Some(first_start) -> {
      let first_end = segment_end(line, first_start)
      case string.slice(line, at_index: first_end, length: 1) {
        "," ->
          case skip_spaces(line, first_end + 1) {
            option.Some(second_start) -> {
              let second_end = segment_end(line, second_start)
              case string.slice(line, at_index: second_end, length: 2) == ">>" {
                True ->
                  option.Some(#(
                    first_start,
                    first_end,
                    second_start,
                    second_end,
                  ))
                False -> option.None
              }
            }
            option.None -> option.None
          }
        _ -> option.None
      }
    }
  }
}

/// The end of a bit-string segment: characters up to `,` or `>`.
fn segment_end(line: String, from: Int) -> Int {
  case from >= string.length(line) {
    True -> from
    False -> {
      let ch = string.slice(line, at_index: from, length: 1)
      case ch == "," || ch == ">" {
        True -> from
        False -> segment_end(line, from + 1)
      }
    }
  }
}

fn pipe_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    let line = fetch(lines, idx)
    case find_pipe_swap(line) {
      option.None -> []
      option.Some(#(pipe_start, call_start, arg_start, arg_end)) -> {
        // the piped value is the token ending just before `|>`
        case find_token_before(line, pipe_start) {
          option.None -> []
          option.Some(#(val_start, val_end)) -> {
            let piped =
              string.slice(
                line,
                at_index: val_start,
                length: val_end - val_start,
              )
            let arg =
              string.slice(
                line,
                at_index: arg_start,
                length: arg_end - arg_start,
              )
            let swapped =
              string.slice(line, at_index: 0, length: val_start)
              <> arg
              <> string.slice(
                line,
                at_index: val_end,
                length: arg_start - val_end,
              )
              <> piped
              <> string.slice(
                line,
                at_index: arg_end,
                length: string.length(line) - arg_end,
              )
            case piped == arg {
              True -> []
              False -> [#("pipe swap", source_of(lines, idx, swapped))]
            }
          }
        }
      }
    }
  })
  |> list.flatten
}

/// Find `x |> f(a)` on `line`: the `|>` pipe, the call after it, and the call's
/// single simple argument. Returns their byte offsets.
fn find_pipe_swap(line: String) -> option.Option(#(Int, Int, Int, Int)) {
  case string.contains(line, "|>") {
    False -> option.None
    True ->
      find_pipe_index(line, 0)
      |> option.then(fn(pipe_index) {
        case find_first_paren_after(line, pipe_index + 2) {
          option.Some(call_open) ->
            case read_one_arg_call(line, call_open) {
              option.Some(#(_call_start, arg_start, arg_end)) ->
                option.Some(#(pipe_index, call_open, arg_start, arg_end))
              option.None -> option.None
            }
          option.None -> option.None
        }
      })
  }
}

/// Given `line` and the index of a `(`, read `tok)`. Returns
/// `#(call_start, arg_start, arg_end)` if the paren contains exactly one
/// simple token followed by `)`.
fn read_one_arg_call(
  line: String,
  open_index: Int,
) -> option.Option(#(Int, Int, Int)) {
  case first_simple_start(line, open_index + 1) {
    option.None -> option.None
    option.Some(arg_start) -> {
      let arg_end = simple_token_end(line, arg_start)
      case string.slice(line, at_index: arg_end, length: 1) {
        ")" -> option.Some(#(open_index, arg_start, arg_end))
        _ -> option.None
      }
    }
  }
}

fn find_pipe_index(line: String, index: Int) -> option.Option(Int) {
  case index + 1 >= string.length(line) {
    True -> option.None
    False ->
      case string.slice(line, at_index: index, length: 2) == "|>" {
        True -> option.Some(index)
        False -> find_pipe_index(line, index + 1)
      }
  }
}

fn find_first_paren_after(line: String, from: Int) -> option.Option(Int) {
  case from >= string.length(line) {
    True -> option.None
    False ->
      case string.slice(line, at_index: from, length: 1) {
        "(" -> option.Some(from)
        _ -> find_first_paren_after(line, from + 1)
      }
  }
}

/// The byte offsets of the identifier or literal immediately before `index`,
/// skipping any whitespace between it and `index`.
fn find_token_before(line: String, index: Int) -> option.Option(#(Int, Int)) {
  let end = skip_spaces_back(line, index)
  case end <= 0 {
    True -> option.None
    False ->
      case
        is_simple_arg_char(string.slice(line, at_index: end - 1, length: 1))
      {
        True -> option.Some(#(token_start(line, end - 1), end))
        False -> option.None
      }
  }
}

fn skip_spaces_back(line: String, index: Int) -> Int {
  case index > 0 && string.slice(line, at_index: index - 1, length: 1) == " " {
    True -> skip_spaces_back(line, index - 1)
    False -> index
  }
}

fn token_start(line: String, index: Int) -> Int {
  case index <= 0 {
    True -> 0
    False ->
      case
        is_simple_arg_char(string.slice(line, at_index: index - 1, length: 1))
      {
        True -> token_start(line, index - 1)
        False -> index
      }
  }
}

/// Kind `importfn`: rename an explicitly imported function or type
/// (`import gleam/list.{append}`), so import item resolution must fail.
fn importfn_mutants(lines: List(String)) -> List(Mutant) {
  list.index_map(lines, fn(_line, idx) {
    let line = fetch(lines, idx)
    case string.starts_with(line, "import ") && string.contains(line, ".{") {
      False -> []
      True -> {
        let items = import_items(line)
        list.map(items, fn(item) {
          let renamed = item <> "__zzz"
          #(
            "importfn " <> item,
            string.replace(line, each: item, with: renamed),
          )
        })
      }
    }
  })
  |> list.flatten
}

/// The explicitly imported names after `.{` on an import line, e.g. `["append"]`
/// from `import gleam/list.{append}` or `["List", "map"]` from
/// `import gleam/list.{type List, map}`.
fn import_items(line: String) -> List(String) {
  case string.split_once(line, ".{") {
    Error(_) -> []
    Ok(#(_before, after)) -> {
      let stripped = string.replace(after, each: "}", with: "")
      stripped
      |> string.split(",")
      |> list.map(string.trim)
      |> list.filter(fn(item) { item != "" })
      |> list.map(fn(item) {
        // `type List` -> `List`
        case string.split_once(item, " ") {
          Ok(#(_kw, name)) -> name
          Error(_) -> item
        }
      })
    }
  }
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
  |> list.append(bitstring_mutants(lines))
  |> list.append(literal_mutants(lines))
  |> list.append(arg_mutants(lines))
  |> list.append(lblarg_mutants(lines))
  |> list.append(arity_mutants(lines))
  |> list.append(negate_mutants(lines))
  |> list.append(letpat_mutants(lines))
  |> list.append(sigswap_mutants(lines))
  |> list.append(pipe_mutants(lines))
  |> list.append(casepat_mutants(lines))
  |> list.append(clausepat_mutants(lines))
  |> list.append(guard_mutants(lines))
  |> list.append(typeparam_mutants(lines))
  |> list.append(bitreorder_mutants(lines))
  |> list.append(letswap_mutants(lines))
  |> list.append(importfn_mutants(lines))
  |> list.append(use_mutants(lines))
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
        #(True, option.Some(previous)) ->
          case is_identifier_char(previous) {
            True ->
              name_spans_from(line, index + 1, start, option.Some(ch), acc)
            False ->
              name_spans_from(line, index + 1, index, option.Some(ch), acc)
          }
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

/// Whether glimpse's dev_check reports all modules typechecked. Runs in-process
/// (no `gleam run -m dev_check` subprocess) so the worker's Erlang VM and the
/// project's cached build are reused across mutants instead of booting a fresh
/// process and re-running the build graph check each time.
fn glimpse_check(root: String) -> Bool {
  case dev_check.run_typecheck(option.Some(root)) {
    Ok(_) -> True
    Error(_) -> False
  }
}
