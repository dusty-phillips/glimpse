import typecheck/helpers

/// Field access on a multi-constructor custom type where the constructor names
/// differ from the type name. The field's type must be resolved through the
/// type's constructors, not by looking up the type name as a definition.
pub fn multi_constructor_field_access_test() {
  let #(_module, _env) =
    helpers.ok_module_typecheck(
      "pub type Shape {
        Circle(location: String, radius: Int)
        Rect(location: String, width: Int, height: Int)
      }
    fn origin(shape: Shape) -> String {
      shape.location
    }",
    )
}

/// Field access on a single-constructor record type. This is the common case
/// and must keep working alongside multi-constructor types.
pub fn single_constructor_field_access_test() {
  let #(_module, _env) =
    helpers.ok_module_typecheck(
      "pub type Point { Point(x: Int, y: Int) }
    fn x_of(point: Point) -> Int {
      point.x
    }",
    )
}

/// Chained field access on nested custom types (`record.inner.label`).
pub fn nested_field_access_test() {
  let #(_module, _env) =
    helpers.ok_module_typecheck(
      "pub type Outer { Outer(inner: Inner) }
    pub type Inner { Inner(label: String) }
    fn label_of(outer: Outer) -> String {
      outer.inner.label
    }",
    )
}

/// Field access on a generic custom type must yield the field type expressed in
/// terms of the container's actual type parameter, not a fresh unrelated
/// variable. Accessing `.function` on `Decoder(Int)` gives a decoder of `Int`.
pub fn generic_field_access_concrete_container_test() {
  let #(module, _env) =
    helpers.ok_module_typecheck(
      "pub type Decoder(a) { Decoder(function: fn(Int) -> #(a, String)) }
    fn get_int(decoder: Decoder(Int)) -> fn(Int) -> #(Int, String) {
      decoder.function
    }",
    )
  let assert [function] = module.module.functions
  assert function.definition.name == "get_int"
}

/// Two field accesses on the same generic type must not collapse their
/// parameters into one. Accessing `.function` on `Decoder(key)` and
/// `Decoder(value)` keeps `key` and `value` distinct.
pub fn generic_field_access_distinct_params_test() {
  let #(_module, _env) =
    helpers.ok_module_typecheck(
      "pub type Decoder(a) { Decoder(function: fn(Int) -> #(a, String)) }
    pub fn pair(
      key_decoder: Decoder(key),
      value_decoder: Decoder(value),
    ) -> Decoder(#(key, value)) {
      Decoder(function: fn(data) {
        let #(key, errors) = key_decoder.function(data)
        #(#(key, key), errors)
      })
    }",
    )
}

/// A constructor pattern that rebinds a variable with the same name as the
/// subject (e.g. `case state { Http2(state) }`) must not stamp the outer
/// constructor's variant index onto the rebound variable's own type. Here
/// `Http2` is variant 1 of `State` but the inner `state` is a `ChildState`
/// whose constructor is variant 0; field access on it must still resolve.
pub fn pattern_rebinding_subject_name_test() {
  let #(_module, _env) =
    helpers.ok_module_typecheck(
      "pub type State {
        Http1(conn: Int)
        Http2(state: ChildState)
      }
    pub type ChildState {
      ChildState(port: Int)
    }
    pub fn port_of(state: State) -> Int {
      case state {
        Http2(state) -> state.port
        Http1(_) -> 0
      }
    }",
    )
}

/// A plain function whose return type is a custom type must not be treated as a
/// record field of that type, even when it carries a matching parameter label.
/// `insert` returns `Box` and labels a parameter `insert`, so `box.insert`
/// would otherwise resolve to the parameter type rather than failing record
/// access.
pub fn plain_function_returning_type_is_not_field_test() {
  let #(_module, _env) =
    helpers.ok_module_typecheck(
      "pub type Box { Box(contents: Int) }
    pub fn insert(into box: Box, insert value: Int) -> Box {
      Box(value)
    }
    pub fn main(box: Box) -> Int {
      box.contents
    }",
    )
}

/// Piping a value into an unannotated function parameter used as a callable
/// (`request |> service`) must unify the parameter into a function type rather
/// than failing with NotCallable.
pub fn pipe_into_unannotated_parameter_test() {
  let #(_module, _env) =
    helpers.ok_module_typecheck(
      "pub fn apply(service) -> Int {
      1 |> service
    }",
    )
}
