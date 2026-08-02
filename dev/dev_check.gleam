import glance
import gleam/dict
import gleam/erlang/charlist
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import glimpse
import glimpse/internal/import_dependencies
import glimpse/internal/typecheck/types
import glimpse/typecheck

pub fn main() {
  let dir = "src"
  let package_name = "glimpse"
  io.println("Typechecking: " <> dir <> " (package: " <> package_name <> ")")
  case run_typecheck(dir, package_name) {
    Ok(Nil) -> io.println("OK: all modules typechecked")
    Error(msg) -> io.println("FAIL: " <> msg)
  }
}

fn run_typecheck(dir: String, package_name: String) -> Result(Nil, String) {
  let dir = case string.ends_with(dir, "/") {
    True -> dir
    False -> dir <> "/"
  }
  use project_files <- result.try(list_gleam_files(dir))
  io.println(
    "Found "
    <> string.inspect(list.length(project_files))
    <> " project .gleam files",
  )

  let project_entries =
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
                "  Parse error in "
                <> path
                <> ": "
                <> string.inspect(parse_error),
              )
              Ok(acc)
            }
          }
        }
      }
    })

  use ok_entries <- result.try(project_entries)

  let dep_entries = scan_build_packages()
  io.println(
    "Found "
    <> string.inspect(list.length(dep_entries))
    <> " dependency .gleam files",
  )

  let all_entries = list.append(dep_entries, ok_entries)
  let module_dict = dict.from_list(all_entries)
  let package = glimpse.Package(package_name, module_dict)
  io.println(
    "Parsed " <> string.inspect(list.length(all_entries)) <> " modules total",
  )

  let import_graph =
    dict.map_values(package.modules, fn(_, value) { value.dependencies })

  use ordered <- result.try(
    import_dependencies.sort_dependencies(import_graph, package_name)
    |> result.map_error(string.inspect),
  )

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
          case typecheck.module(glimpse_module, module_envs) {
            Error(err) -> Error(next_module <> ": " <> string.inspect(err))
            Ok(#(_, module_env)) ->
              Ok(dict.insert(module_envs, next_module, module_env))
          }
      }
    },
  )
  |> result.map(fn(_) { Nil })
}

fn scan_build_packages() -> List(#(String, glimpse.Module)) {
  let base = "build/packages/"
  case list_dir(base) {
    Ok(packages) ->
      list.filter_map(packages, fn(pkg) {
        let src_dir =
          string.append(string.append(string.append(base, pkg), "/"), "src")
        list_gleam_files(src_dir)
        |> result.map(fn(files) {
          list.filter_map(files, fn(path) {
            let module_name = dep_path_to_module_name(pkg, path)
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

fn dep_path_to_module_name(pkg: String, path: String) -> String {
  let prefix = "build/packages/" <> pkg <> "/src/"
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

@external(erlang, "file", "list_dir")
fn list_dir_raw(path: String) -> Result(List(a), Nil)

@external(erlang, "file", "read_file")
fn read_file_raw(path: String) -> Result(String, Nil)

@external(erlang, "filelib", "is_dir")
pub fn is_dir(path: String) -> Bool

pub fn list_dir(path: String) -> Result(List(String), String) {
  case list_dir_raw(path) {
    Ok(entries) ->
      Ok(list.map(entries, fn(entry) { charlist.to_string(entry) }))
    Error(_) -> Error("list_dir(" <> path <> ") failed")
  }
}

pub fn read_file(path: String) -> String {
  case read_file_raw(path) {
    Ok(content) -> content
    Error(_) -> {
      io.println_error("Warning: could not read " <> path)
      ""
    }
  }
}
