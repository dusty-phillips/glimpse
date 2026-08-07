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
import glimpse/internal/target
import glimpse/internal/typecheck/types
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

fn run_typecheck(extra_project: option.Option(String)) -> Result(Nil, String) {
  use src_entries <- result.try(case extra_project {
    option.None -> scan_project_dir("src")
    option.Some(root) -> {
      let root = case string.ends_with(root, "/") {
        True -> root
        False -> root <> "/"
      }
      scan_project_dir(root <> "src")
    }
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
    option.Some(root) -> {
      let root = case string.ends_with(root, "/") {
        True -> root
        False -> root <> "/"
      }
      scan_build_packages(root <> "build/packages/")
    }
  }
  io.println(
    "Found "
    <> string.inspect(list.length(dep_entries))
    <> " dependency modules",
  )

  let all_entries = list.flatten([dep_entries, src_entries, dev_entries])
  let module_dict = dict.from_list(all_entries)
  let package_name = case extra_project {
    option.Some(root) -> {
      let parts = root |> string.split("/") |> list.filter(fn(p) { p != "" })
      list.last(parts) |> result.unwrap("checkout")
    }
    option.None -> "glimpse"
  }
  let package = glimpse.Package(package_name, module_dict, [])
  io.println(
    "Parsed " <> string.inspect(list.length(all_entries)) <> " modules total",
  )

  let import_graph =
    dict.map_values(package.modules, fn(_, value) { value.dependencies })

  use ordered <- result.try(sort_from_all_roots(import_graph))

  list.try_fold(
    ordered,
    dict.new(),
    fn(module_envs: dict.Dict(String, types.Environment), next_module: String) -> Result(
      dict.Dict(String, types.Environment),
      String,
    ) {
      io.println("  typechecking: " <> next_module)
      case dict.get(package.modules, next_module) {
        Error(_) -> Error("missing module " <> next_module)
        Ok(glimpse_module) ->
          case typecheck.module(glimpse_module, module_envs, build_target) {
            Error(err) -> Error(next_module <> ": " <> string.inspect(err))
            Ok(#(_, module_env)) ->
              Ok(dict.insert(module_envs, next_module, module_env))
          }
      }
    },
  )
  |> result.map(fn(_) { Nil })
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
            Ok(acc)
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

/// Sort the import graph starting from every module that nothing imports, so
/// standalone entry points (e.g. `dev_check`) and their dependencies are all
/// typechecked, not just the modules reachable from the main package module.
fn sort_from_all_roots(
  import_graph: dict.Dict(String, List(String)),
) -> Result(List(String), String) {
  let imported =
    dict.fold(import_graph, set.new(), fn(acc, _, deps) {
      set.union(acc, set.from_list(deps))
    })
  let roots =
    list.filter(dict.keys(import_graph), fn(m) { !set.contains(imported, m) })

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
