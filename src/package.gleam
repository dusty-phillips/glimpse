import glance
import gleam/dict
import gleam/list

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
  Package(name: String, modules: dict.Dict(String, glance.Module))
}

/// Given an existing Gleam Module and its name, parse its imports to determine
/// what its dependencies are. Return a Glimpse Module that wraps the Gleam module.
///
/// Note: If the returned Module has any dependencies, it is up to the caller to ensure
/// they are loaded, along with their dependencies.
pub fn extract_dependencies(module: glance.Module, name: String) -> Module {
  module.imports
  |> list.map(fn(import_def) {
    case import_def {
      glance.Definition(definition: import_, ..) -> import_.module
    }
  })
  |> Module(name, module, _)
}
