import glimpse/error
import typecheck/helpers

pub fn field_not_in_all_variants_test() {
  assert helpers.error_module_typecheck(
      "pub type Person {
    Teacher(name: String, age: Int, title: String)
    Student(name: String, age: Int)
  }
  pub fn get_title(person: Person) {
    person.title
  }",
    )
    == error.MissingField(
      "main_module.Person does not have field title on every variant",
    )
}

pub fn field_at_different_position_across_variants_test() {
  assert helpers.error_module_typecheck(
      "pub type Person {
    Teacher(title: String, age: Int, name: String)
    Student(name: String, age: Int)
  }
  pub fn main(p: Person) {
    p.name
  }",
    )
    == error.MissingField(
      "main_module.Person has field name at different positions on its variants",
    )
}

pub fn shared_field_same_position_test() {
  helpers.ok_module_typecheck(
    "pub type Person {
    Teacher(name: String, age: Int)
    Student(name: String, age: Int)
  }
  pub fn get_name(person: Person) {
    person.name
  }",
  )
}

pub fn field_access_on_single_variant_still_works_test() {
  helpers.ok_module_typecheck(
    "pub type Point {
    Point(x: Int, y: Int)
  }
  pub fn get_x(p: Point) {
    p.x
  }",
  )
}
