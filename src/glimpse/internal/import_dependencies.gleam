import gleam/dict
import gleam/list
import gleam/result
import gleam/set
import glimpse/error

/// Type alias for sorting dependencies.
pub type ImportGraph =
  dict.Dict(String, List(String))

type FoldState {
  FoldState(visited: set.Set(String), oldest_list_first: List(String))
}

/// Given a dict representing a graph mapping module names to the names of modules
/// that module imports, return a list of all modules in the graph that are reachable 
/// via import from the given entry_point module.
///
/// Any modules in the graph not reachable from the entry_point will be exculided.
///
/// The resulting list will be ordered from leaf node to entry_point. If you process it
/// in order from head to tail, you will never encounter a module that imports a module
/// that has not already be processed.
///
/// Returns a CircularDependencyError if there are circular depnedencies, or a NotFoundError
/// if a module imports a module that is not in the input graph.
pub fn sort_dependencies(
  dependencies: ImportGraph,
  entry_point: String,
) -> Result(List(String), error.GlimpseError(a)) {
  sort_dependencies_recursive(dependencies, set.new(), set.new(), entry_point)
  |> result.map_error(error.ImportError)
  |> result.map(list.reverse)
}

/// Perform a depth-first sorting of the graph. ancestors of the current node
/// are maintained in a set to detect cycles, and a visited set is used
/// to avoid replicated work.
///
/// This function is NOT currently tail recursive.
fn sort_dependencies_recursive(
  maybe_dag: ImportGraph,
  ancestors: set.Set(String),
  visited: set.Set(String),
  module: String,
) -> Result(List(String), error.GlimpseImportError) {
  case
    set.contains(ancestors, module),
    dict.get(maybe_dag, module),
    set.contains(visited, module)
  {
    True, _, _ -> Error(error.CircularDependencyError(module))
    False, Error(_), _ -> Error(error.MissingImportError(module))
    False, Ok(_), True -> Ok([])
    False, Ok([]), False -> Ok([module])
    False, Ok(dependencies), False -> {
      let next_ancestors = set.insert(ancestors, module)
      list.fold(dependencies, Ok(FoldState(visited, [])), fn(state_result, dep) {
        use state <- result.try(state_result)
        use sort_result <- result.try(sort_dependencies_recursive(
          maybe_dag,
          next_ancestors,
          state.visited,
          dep,
        ))
        let next_visited =
          set.from_list(sort_result) |> set.union(state.visited)
        Ok(FoldState(
          next_visited,
          list.append(sort_result, state.oldest_list_first),
        ))
      })
      |> result.map(fn(state) { list.prepend(state.oldest_list_first, module) })
    }
  }
}
