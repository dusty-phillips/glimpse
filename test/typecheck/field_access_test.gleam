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
