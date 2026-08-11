import argv
import glance
import gleam/dict
import gleam/io
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import glimpse
import glimpse/internal/import_dependencies
import glimpse/internal/typecheck/types
import glimpse/target
import glimpse/typecheck
import simplifile

/// Run as `glimmer dev_check` to typecheck this package's own modules and its
/// cached dependencies, or as `glimmer dev_check --typecheck <root>` to
/// typecheck an external Gleam project checkout instead. `<root>` must be a
/// project root (run `gleam build` in it first so its dependencies are
/// cached): its `src/` modules are loaded under their real names (e.g.
/// `storail.gleam` -> module `storail`) and its `build/packages/` cache
/// provides the transitive dependencies. When `--typecheck` is given only the
/// checkout is checked; this package's own modules and cache are not included.
pub fn main() {
  let extra = parse_extra_dir(argv.load().arguments)
  let package_name = "glimpse"
  case extra {
    option.None ->
      io.println("Typechecking: src/ + dev/ (package: " <> package_name <> ")")
    option.Some(root) -> io.println("Typechecking extra: " <> root)
  }
  case run_typecheck(extra) {
    Ok(Nil) -> io.println("OK: all modules typechecked")
    Error(msg) -> io.println("FAIL: " <> msg)
  }
}

fn parse_extra_dir(argv: List(String)) -> option.Option(String) {
  case argv {
    ["--typecheck", path, ..] -> option.Some(path)
    [_, ..rest] -> parse_extra_dir(rest)
    [] -> option.None
  }
}

/// The precomputed, immutable result of typechecking a whole project once. The
/// mutation harness builds this once per invocation and re-checks individual
/// mutated modules against it, so unchanged modules (and their parsed sources)
/// are never re-read, re-parsed, or re-typechecked.
pub type Baseline {
  Baseline(
    package_name: String,
    modules: dict.Dict(String, glimpse.Module),
    envs: dict.Dict(String, types.Environment),
    ordered: List(String),
    importers: dict.Dict(String, List(String)),
    target: target.Target,
  )
}

/// A [Baseline] can be huge (every module environment embeds the map of all
/// module environments, for field access on unimported modules). Erlang
/// `spawn` copies a spawned fun's captured variables into the new process's
/// heap, so handing the baseline to each harness worker through a closure
/// capture would duplicate that whole graph per worker. Instead the harness
/// stores the baseline once in a `persistent_term` and each worker reads it
/// back by key, which shares the term without copying it.
@external(erlang, "persistent_term", "put")
pub fn store_baseline(key: String, baseline: Baseline) -> Nil

@external(erlang, "persistent_term", "get")
pub fn fetch_baseline(key: String) -> Baseline

@external(erlang, "persistent_term", "erase")
pub fn erase_baseline(key: String) -> Bool

/// Typecheck the package rooted at `extra_project` (when given) or this
/// package's own `src/` and `dev/`, returning the typecheck result. Prints
/// nothing itself so callers (like the mutation harness) can run it in-process
/// without noise.
pub fn run_typecheck(
  extra_project: option.Option(String),
) -> Result(Nil, String) {
  build_baseline(extra_project)
  |> result.map(fn(_) { Nil })
}

/// Parse every module of the project and typecheck all of them, returning the
/// cached [Baseline]. The baseline must typecheck cleanly; callers that re-check
/// individual modules against it trust the unchanged modules' environments.
pub fn build_baseline(
  extra_project: option.Option(String),
) -> Result(Baseline, String) {
  use src_entries <- result.try(case extra_project {
    option.None -> scan_project_dir("src")
    option.Some(root) -> scan_project_dir(with_trailing_slash(root) <> "src")
  })

  let build_target = case extra_project {
    option.Some(root) -> target_from_project(root)
    option.None -> target.Erlang
  }

  use dev_entries <- result.try(case extra_project {
    option.None -> scan_project_dir("dev")
    option.Some(_) -> Ok([])
  })

  let dep_entries = case extra_project {
    option.None -> scan_build_packages("build/packages/")
    option.Some(root) ->
      scan_build_packages(with_trailing_slash(root) <> "build/packages/")
  }

  let all_entries = list.flatten([dep_entries, src_entries, dev_entries])
  let module_dict = dict.from_list(all_entries)
  let package_name = case extra_project {
    option.Some(root) -> {
      let parts = root |> string.split("/") |> list.filter(fn(p) { p != "" })
      list.last(parts) |> result.unwrap("checkout")
    }
    option.None -> "glimpse"
  }

  let import_graph =
    dict.map_values(module_dict, fn(_, value) { value.dependencies })

  use ordered <- result.try(sort_from_all_roots(import_graph))

  let project_modules =
    list.map(src_entries, fn(entry) { entry.0 })
    |> list.append(list.map(dev_entries, fn(entry) { entry.0 }))
    |> set.from_list

  use envs <- result.try(fold_typecheck(
    module_dict,
    ordered,
    dict.new(),
    build_target,
    project_modules,
  ))

  Ok(Baseline(
    package_name,
    module_dict,
    envs,
    ordered,
    reverse_graph(import_graph),
    build_target,
  ))
}

/// Re-typecheck a single mutated module against a precomputed [Baseline]. The
/// mutant is read from `<worker_root>/<src_rel>` (the harness writes it there);
/// every other module's parsed source and environment comes from the baseline.
///
/// Only the mutated module and the modules that import it (transitively) are
/// re-typechecked: a module's environment depends only on its own definitions
/// and its imports' environments, so no other module can be affected.
pub fn recheck_mutated(
  baseline: Baseline,
  worker_root: String,
  src_rel: String,
) -> Result(Nil, String) {
  let path = "/" <> string.join([worker_root, src_rel], "/")
  use mutated_source <- result.try(
    simplifile.read(from: path)
    |> result.map_error(fn(_) { "cannot read " <> path }),
  )
  use mutated_glance <- result.try(
    glance.module(mutated_source)
    |> result.map_error(fn(_) { "parse error in " <> path }),
  )
  let mutated_name = src_rel_to_module_name(src_rel)
  let mutated_module = glimpse.load_module(mutated_glance, mutated_name)

  let affected = transitive_importers(baseline.importers, mutated_name)
  let modules = dict.insert(baseline.modules, mutated_name, mutated_module)
  let envs =
    dict.filter(baseline.envs, fn(name, _) { !list.contains(affected, name) })
  let affected_ordered =
    list.filter(baseline.ordered, fn(name) { list.contains(affected, name) })

  fold_typecheck(
    modules,
    affected_ordered,
    envs,
    baseline.target,
    set.from_list(affected),
  )
  |> result.map(fn(_) { Nil })
}

/// The module name of a `src/`-relative path like `src/lustre/element.gleam`
/// (`lustre/element`), matching how the baseline named its src modules.
fn src_rel_to_module_name(src_rel: String) -> String {
  let name = case string.starts_with(src_rel, "src/") {
    True -> string.drop_start(src_rel, 4)
    False -> src_rel
  }
  string.drop_end(name, 6)
}

/// The name of every module that imports `start`, transitively, plus `start`
/// itself.
fn transitive_importers(
  importers: dict.Dict(String, List(String)),
  start: String,
) -> List(String) {
  transitive_importers_(importers, [start], set.new())
}

fn transitive_importers_(
  importers: dict.Dict(String, List(String)),
  frontier: List(String),
  seen: set.Set(String),
) -> List(String) {
  case frontier {
    [] -> set.to_list(seen)
    [name, ..rest] -> {
      case set.contains(seen, name) {
        True -> transitive_importers_(importers, rest, seen)
        False -> {
          let seen = set.insert(seen, name)
          let next = dict.get(importers, name) |> result.unwrap([])
          transitive_importers_(importers, list.append(next, rest), seen)
        }
      }
    }
  }
}

/// Invert an import graph (`module` -> `dependencies`) into a map of
/// `module` -> modules that import it.
fn reverse_graph(
  import_graph: dict.Dict(String, List(String)),
) -> dict.Dict(String, List(String)) {
  list.fold(dict.to_list(import_graph), dict.new(), fn(acc, entry) {
    let #(module_name, deps) = entry
    list.fold(deps, acc, fn(acc2, dep) {
      let importers = dict.get(acc2, dep) |> result.unwrap([])
      dict.insert(acc2, dep, [module_name, ..importers])
    })
  })
}

fn with_trailing_slash(dir: String) -> String {
  case string.ends_with(dir, "/") {
    True -> dir
    False -> dir <> "/"
  }
}

/// Typecheck `ordered` modules (dependencies first) in turn, threading the
/// growing map of module environments seeded from `envs`. `modules` must
/// contain every name in `ordered`. Target support (a public bodyless
/// external without an implementation for the active target) is enforced only
/// for the package's own modules — `project_modules` — matching the real
/// compiler, which does not enforce it for dependencies.
fn fold_typecheck(
  modules: dict.Dict(String, glimpse.Module),
  ordered: List(String),
  envs: dict.Dict(String, types.Environment),
  target: target.Target,
  project_modules: set.Set(String),
) -> Result(dict.Dict(String, types.Environment), String) {
  list.try_fold(
    ordered,
    envs,
    fn(module_envs: dict.Dict(String, types.Environment), next_module: String) -> Result(
      dict.Dict(String, types.Environment),
      String,
    ) {
      case dict.get(modules, next_module) {
        Error(_) -> Error("missing module " <> next_module)
        Ok(glimpse_module) ->
          case
            typecheck.module(
              glimpse_module,
              module_envs,
              target,
              set.contains(project_modules, next_module),
            )
          {
            Error(err) -> Error(next_module <> ": " <> string.inspect(err))
            Ok(#(_, module_env)) ->
              Ok(dict.insert(module_envs, next_module, module_env))
          }
      }
    },
  )
}

/// Scan a project source directory (`src/` or `dev/`) for .gleam modules.
fn scan_project_dir(
  dir: String,
) -> Result(List(#(String, glimpse.Module)), String) {
  let dir = case string.ends_with(dir, "/") {
    True -> dir
    False -> dir <> "/"
  }
  use project_files <- result.try(list_gleam_files(dir))
  io.println(
    "Found "
    <> string.inspect(list.length(project_files))
    <> " project .gleam files in "
    <> dir,
  )

  list.fold(project_files, Ok([]), fn(state, path) {
    case state {
      Error(_) -> state
      Ok(acc) -> {
        let module_name = path_to_module_name(dir, path)
        case glance.module(read_file(path)) {
          Ok(glance_module) ->
            Ok([
              #(module_name, glimpse.load_module(glance_module, module_name)),
              ..acc
            ])
          Error(parse_error) -> {
            io.println_error(
              "  Parse error in " <> path <> ": " <> string.inspect(parse_error),
            )
            Error("parse error in " <> path)
          }
        }
      }
    }
  })
}

/// Read the build target from a project's `gleam.toml`, defaulting to Erlang.
fn target_from_project(root: String) -> target.Target {
  let root = case string.ends_with(root, "/") {
    True -> root
    False -> root <> "/"
  }
  let toml = read_file(root <> "gleam.toml")
  case
    toml
    |> string.split("\n")
    |> list.find(fn(line) { string.starts_with(string.trim(line), "target") })
  {
    Ok(line) ->
      case string.contains(line, "javascript") {
        True -> target.Javascript
        False -> target.Erlang
      }
    Error(_) -> target.Erlang
  }
}

/// Sort the import graph starting from every module, so standalone entry
/// points (e.g. `dev_check`) and their dependencies are all typechecked, not
/// just the modules reachable from the main package module. Sorting from every
/// module also catches import cycles anywhere in the graph: a module in a cycle
/// is never a root (it is imported by another cycle member), so a root-only
/// traversal would silently skip a pure or disconnected cycle.
fn sort_from_all_roots(
  import_graph: dict.Dict(String, List(String)),
) -> Result(List(String), String) {
  let roots = dict.keys(import_graph)

  list.try_fold(roots, [], fn(acc, root) {
    use sorted <- result.try(
      import_dependencies.sort_dependencies(import_graph, root)
      |> result.map_error(string.inspect),
    )
    Ok(
      list.fold(sorted, acc, fn(acc2, m) {
        case list.contains(acc2, m) {
          True -> acc2
          False -> list.append(acc2, [m])
        }
      }),
    )
  })
}

fn scan_build_packages(base: String) -> List(#(String, glimpse.Module)) {
  case list_dir(base) {
    Ok(packages) ->
      list.filter_map(packages, fn(pkg) {
        let src_dir = base <> pkg <> "/src"
        list_gleam_files(src_dir)
        |> result.map(fn(files) {
          list.filter_map(files, fn(path) {
            let module_name = dep_path_to_module_name(base, pkg, path)
            case glance.module(read_file(path)) {
              Ok(glance_module) ->
                Ok(#(
                  module_name,
                  glimpse.load_module(glance_module, module_name),
                ))
              Error(_) -> Error(Nil)
            }
          })
        })
      })
      |> list.flatten
    Error(_) -> []
  }
}

fn dep_path_to_module_name(base: String, pkg: String, path: String) -> String {
  let prefix = base <> pkg <> "/src/"
  let relative = string.drop_start(path, string.length(prefix))
  let relative = case string.starts_with(relative, "/") {
    True -> string.drop_start(relative, 1)
    False -> relative
  }
  string.replace(relative, ".gleam", "")
}

fn path_to_module_name(root: String, path: String) -> String {
  let relative = string.drop_start(path, string.length(root))
  let relative = case string.starts_with(relative, "/") {
    True -> string.drop_start(relative, 1)
    False -> relative
  }
  string.replace(relative, ".gleam", "")
}

fn list_gleam_files(dir: String) -> Result(List(String), String) {
  list_dir_recursive(dir)
  |> result.map(fn(paths) {
    list.filter(paths, fn(path) {
      string.ends_with(path, ".gleam") && !string.contains(path, "/.")
    })
  })
}

fn list_dir_recursive(dir: String) -> Result(List(String), String) {
  use entries <- result.try(
    list_dir(dir)
    |> result.map_error(fn(_) { "Cannot read directory: " <> dir }),
  )
  let full_paths =
    list.map(entries, fn(entry) {
      string.append(string.append(dir, "/"), entry)
    })
  let #(subdirs, files) = list.partition(full_paths, is_dir)
  use subdir_files <- result.try(
    list.try_map(subdirs, list_dir_recursive)
    |> result.map_error(fn(_) { "Failed to scan subdirectory" }),
  )
  Ok(list.flatten([files, ..subdir_files]))
}

pub fn list_dir(path: String) -> Result(List(String), String) {
  case simplifile.read_directory(at: path) {
    Ok(entries) -> Ok(entries)
    Error(_) -> Error("list_dir(" <> path <> ") failed")
  }
}

pub fn read_file(path: String) -> String {
  case simplifile.read(from: path) {
    Ok(content) -> content
    Error(_) -> {
      io.println_error("Warning: could not read " <> path)
      ""
    }
  }
}

pub fn is_dir(path: String) -> Bool {
  case simplifile.is_directory(path) {
    Ok(result) -> result
    Error(_) -> False
  }
}
