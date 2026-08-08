import gleam/dict
import gleam/list
import gleam/result
import gleam/set
import glimpse/error

/// Type alias for sorting dependencies.
pub type ImportGraph =
  dict.Dict(String, List(String))

type SortFrame {
  SortFrame(
    module: String,
    remaining: List(String),
    ancestors: set.Set(String),
    visited: set.Set(String),
    result: List(String),
  )
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
  sort_dependencies_iterative(dependencies, entry_point)
  |> result.map_error(error.ImportError)
  |> result.map(list.reverse)
}

/// Perform an iterative depth-first sort of the graph using an explicit frame
/// stack, avoiding the stack overflow risk of a recursive traversal on deep
/// import graphs. Each frame tracks the ancestors of its module to detect
/// cycles, a visited set to avoid repeated work, and the partially accumulated
/// result.
fn sort_dependencies_iterative(
  maybe_dag: ImportGraph,
  entry_point: String,
) -> Result(List(String), error.GlimpseImportError) {
  case dict.get(maybe_dag, entry_point) {
    Error(_) -> Error(error.MissingImportError(entry_point))
    Ok(dependencies) ->
      sort_loop(maybe_dag, [
        SortFrame(
          module: entry_point,
          remaining: dependencies,
          ancestors: set.new(),
          visited: set.new(),
          result: [],
        ),
      ])
  }
}

fn sort_loop(
  maybe_dag: ImportGraph,
  stack: List(SortFrame),
) -> Result(List(String), error.GlimpseImportError) {
  case stack {
    [frame, ..rest] ->
      case frame.remaining {
        [] -> {
          let frame_result = list.prepend(frame.result, frame.module)
          let frame_visited =
            frame.visited |> set.union(set.from_list(frame_result))
          case rest {
            [] -> Ok(frame_result)
            [parent, ..grandparents] ->
              sort_loop(maybe_dag, [
                SortFrame(
                  ..parent,
                  visited: set.union(parent.visited, frame_visited),
                  result: list.append(frame_result, parent.result),
                ),
                ..grandparents
              ])
          }
        }
        [dep, ..more] ->
          case set.contains(frame.ancestors, dep) {
            True -> Error(error.CircularDependencyError(dep))
            False ->
              case set.contains(frame.visited, dep) {
                True ->
                  sort_loop(maybe_dag, [
                    SortFrame(..frame, remaining: more),
                    ..rest
                  ])
                False ->
                  case dict.get(maybe_dag, dep) {
                    Error(_) -> Error(error.MissingImportError(dep))
                    Ok(dep_dependencies) ->
                      sort_loop(maybe_dag, [
                        SortFrame(
                          module: dep,
                          remaining: dep_dependencies,
                          ancestors: set.insert(frame.ancestors, frame.module),
                          visited: frame.visited,
                          result: [],
                        ),
                        SortFrame(..frame, remaining: more),
                        ..rest
                      ])
                  }
              }
          }
      }
    [] -> Ok([])
  }
}
