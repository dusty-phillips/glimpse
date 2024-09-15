import glimpse/internal/typecheck/types

pub type VariantField {
  NamedField(name: String, type_: types.Type)
  PositionField(type_: types.Type)
}

pub type Variant {
  Variant(name: String, custom_type: String, fields: List(VariantField))
}
