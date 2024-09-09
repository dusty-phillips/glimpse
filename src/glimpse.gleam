import glance
import gleam/dict
import gleam/list
import gleam/result
import glimpse/error

pub type Module {
  /// A Module is a wrapper of a glance.Module, but maintains some additional
  /// information such as the name of the package and the names of any dependencies
  /// of that module.
  Module(name: String, module: glance.Module, dependencies: List(String))
}

pub type Package {
  /// A Package has a name and a collection of modules. Each module is named
  /// according to its import. A module can be converted to a filename
  ///(relative to the global source / directory) simply by appending '.gleam'
  Package(
    /// The name of the package. Also names the entrypoint module.
    name: String,
    /// Mapping of all modules in the project, from their name to their Module instance
    modules: dict.Dict(String, Module),
  )
}

/// Load a package using just it's name and a loader function. The name is
/// required to be identical to the entry point module for the package (which
/// is normal in gleam packages).
///
/// Recursively loads all imports in the entrypoint using the supplied
/// loader function.
pub fn load_package(
  package_name: String,
  loader: fn(String) -> Result(String, a),
) -> Result(Package, error.GlimpseError(a)) {
  let package = Package(package_name, dict.new())
  load_package_recurse(package, [package_name], loader)
}

/// Given an existing Gleam Module and its name, parse its imports to determine
/// what its dependencies are. Return a Glimpse Module that wraps the Gleam module.
///
/// Note: If the returned Module has any dependencies, it is up to the caller to ensure
/// they are loaded, along with their dependencies.
pub fn load_module(module: glance.Module, name: String) -> Module {
  module.imports
  |> list.map(fn(import_def) {
    case import_def {
      glance.Definition(definition: import_, ..) -> import_.module
    }
  })
  |> Module(name, module, _)
}

/// given a module and package, identify any dependencies in the module that
/// are *not* present in the package, and return them as a list.
/// 
/// The dependencies will be a list of strings like `gleam/io` or `glance`
pub fn filter_new_dependencies(module: Module, package: Package) -> List(String) {
  module.dependencies
  |> list.filter(fn(dep) { !dict.has_key(package.modules, dep) })
}

fn load_package_recurse(
  package: Package,
  modules: List(String),
  loader: fn(String) -> Result(String, a),
) -> Result(Package, error.GlimpseError(a)) {
  case modules {
    [] -> Ok(package)
    [module_name, ..rest] -> {
      case dict.has_key(package.modules, module_name) {
        True -> load_package_recurse(package, rest, loader)
        False -> {
          use module_content <- result.try(
            loader(module_name) |> result.map_error(error.LoadError),
          )
          use glance_module <- result.try(
            glance.module(module_content)
            |> result.map_error(error.ParseError(_, module_name, module_content)),
          )
          let glimpse_module = load_module(glance_module, module_name)
          let unknown_dependencies =
            filter_new_dependencies(glimpse_module, package)
          let recurse_package =
            Package(
              ..package,
              modules: dict.insert(package.modules, module_name, glimpse_module),
            )
          load_package_recurse(
            recurse_package,
            list.append(unknown_dependencies, rest),
            loader,
          )
        }
      }
    }
  }
}
