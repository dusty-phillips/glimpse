import argv
import gleam/io
import gleam/list
import gleam/string
import shellout
import simplifile

/// Differential mutation harness for glimpse's typechecker.
///
/// We take a single source module and generate one mutant per swap of a type
/// annotation (function parameter types and return types) for an incompatible
/// type. For each mutant:
///
///  1. The REAL `gleam check` is run in the project checkout. If it rejects
///     the mutant (non-zero exit), the mutant is a genuine type error and the
///     real compiler gives us ground truth.
///  2. glimpse's `dev_check` is then run against the same checkout. If glimpse
///     ACCEPTS a mutant that the real compiler rejected, that is a FALSE
///     NEGATIVE bug in glimpse.
///
/// Run as:
///   `gleam run -m dev/mutate_check -- --root <work_root> --src <src_rel>`
///
/// `<work_root>` is a buildable copy of the project being tested and
/// `<src_rel>` is the module file under it to mutate, e.g.
/// `src/gleam/string.gleam`. The original file is restored after each mutant.
pub fn main() {
  let args = argv.load().arguments
  case parse_args(args) {
    Error(msg) -> io.println_error(msg)
    Ok(#(root, src)) -> run(root, src)
  }
}

fn parse_args(args: List(String)) -> Result(#(String, String), String) {
  case args {
    ["--root", root, "--src", src, ..] -> Ok(#(root, src))
    _ -> Error("usage: run -m dev/mutate_check -- --root <root> --src <src>")
  }
}

/// Primitive types and mutually incompatible alternatives to try for each.
fn target_types() -> List(#(String, List(String))) {
  [
    #("Int", ["String", "Bool", "Float"]),
    #("String", ["Int", "Bool"]),
    #("Bool", ["Int", "String"]),
    #("Float", ["Int", "String"]),
  ]
}

/// A mutation: swap every occurrence of description.new_type for
/// description.old_type in the file. Applies to the whole file so that both
/// parameter and return position annotations are covered in one pass.
fn run(root: String, src: String) {
  let path = "/" <> string.join([root, src], "/")
  case simplifile.read(from: path) {
    Error(_) -> io.println_error("cannot read " <> path)

    Ok(original) -> {
      let mutants = mutate_file(original)
      io.println(
        "Checking " <> string.inspect(list.length(mutants)) <> " mutants",
      )
      let results = list.map(mutants, fn(mut) { check_one(root, path, mut) })
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
  }
}

/// Build one mutant per (line, type, alternative): swap one type annotation
/// on that single line. Each mutant carries the fully rewritten file content.
fn mutate_file(source: String) -> List(#(String, String, String)) {
  let lines = string.split(source, "\n")
  list.index_map(lines, fn(line, idx) {
    let swaps = swaps_for_line(line)
    list.map(swaps, fn(sw) {
      let new_line = string.replace(line, each: sw.0, with: sw.1)
      let rewritten = string.join(replace_at(lines, idx, new_line), "\n")
      #(sw.0, sw.1, rewritten)
    })
  })
  |> list.flatten
}

type Swap =
  #(String, String)

/// The swaps available for a single line given the types it uses.
fn swaps_for_line(line: String) -> List(Swap) {
  list.flat_map(target_types(), fn(target) {
    let old = target.0
    case string.contains(line, old) {
      False -> []
      True -> list.map(target.1, fn(newtype) { #(old, newtype) })
    }
  })
}

fn replace_at(lines: List(String), idx: Int, line: String) -> List(String) {
  list.index_map(lines, fn(original_line, i) {
    case i == idx {
      True -> line
      False -> original_line
    }
  })
}

fn check_one(
  root: String,
  path: String,
  mut: #(String, String, String),
) -> String {
  let desc = mut.0 <> " -> " <> mut.1
  write(path, mut.2)

  case real_check(root) {
    Ok(_) -> "real-accepts :: " <> desc
    Error(_) ->
      case glimpse_check(root) {
        True -> {
          // dump the false-negative mutant for inspection
          write("/tmp/false.gleam", mut.2)
          "FALSE-NEG :: " <> desc
        }
        False -> "ok :: " <> desc
      }
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
