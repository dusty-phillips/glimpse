import gleam/dict
import gleeunit/should
import glimpse/error
import glimpse/internal/import_dependencies

pub fn sort_empty_dependencies_test() {
  let graph = dict.from_list([#("main_module", [])])

  graph
  |> import_dependencies.sort_dependencies("main_module")
  |> should.be_ok
  |> should.equal(["main_module"])
}

pub fn sort_simple_dependency_test() {
  let graph =
    dict.from_list([#("main_module", ["other_module"]), #("other_module", [])])

  graph
  |> import_dependencies.sort_dependencies("main_module")
  |> should.be_ok
  |> should.equal(["other_module", "main_module"])
}

pub fn sort_diamond_dependency_test() {
  let graph =
    dict.from_list([
      #("main_module", ["a", "b"]),
      #("a", ["c"]),
      #("b", ["c"]),
      #("c", []),
    ])

  graph
  |> import_dependencies.sort_dependencies("main_module")
  |> should.be_ok
  |> should.equal(["c", "a", "b", "main_module"])
}

pub fn sort_arbitrary_complicated_dependency_test() {
  let graph =
    dict.from_list([
      #("main_module", ["a"]),
      #("a", ["b", "c"]),
      #("b", ["d", "g"]),
      #("c", ["d"]),
      #("d", ["e", "f"]),
      #("e", ["g"]),
      #("f", ["g", "h"]),
      #("g", []),
      #("h", []),
    ])

  graph
  |> import_dependencies.sort_dependencies("main_module")
  |> should.be_ok
  |> should.equal(["g", "e", "h", "f", "d", "b", "c", "a", "main_module"])
}

pub fn sort_complete_binary_tree_dependency_test() {
  let graph =
    dict.from_list([
      #("main_module", ["a"]),
      #("a", ["b", "c"]),
      #("b", ["d", "e"]),
      #("c", ["f", "g"]),
      #("d", ["h", "i"]),
      #("e", ["j", "k"]),
      #("f", ["l", "m"]),
      #("g", ["n", "o"]),
      #("h", []),
      #("i", []),
      #("j", []),
      #("k", []),
      #("l", []),
      #("m", []),
      #("n", []),
      #("o", []),
    ])

  graph
  |> import_dependencies.sort_dependencies("main_module")
  |> should.be_ok
  |> should.equal([
    "h", "i", "d", "j", "k", "e", "b", "l", "m", "f", "n", "o", "g", "c", "a",
    "main_module",
  ])
}

pub fn sort_circular_import_test() {
  let graph =
    dict.from_list([
      #("main_module", ["a"]),
      #("a", ["b"]),
      #("b", ["c"]),
      #("c", ["a"]),
    ])

  graph
  |> import_dependencies.sort_dependencies("main_module")
  |> should.be_error
  |> should.equal(error.ImportError(error.CircularDependencyError("a")))
}

pub fn sort_missing_import_test() {
  let graph =
    dict.from_list([
      #("main_module", ["a"]),
      #("a", ["b"]),
      #("b", ["c"]),
      #("c", ["a"]),
    ])

  graph
  |> import_dependencies.sort_dependencies("main_module")
  |> should.be_error
  |> should.equal(error.ImportError(error.CircularDependencyError("a")))
}
