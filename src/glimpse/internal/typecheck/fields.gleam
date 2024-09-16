import glance

/// Helper to extract the item from a Field, ignoring the label
pub fn extract_item(field: glance.Field(a)) -> a {
  let glance.Field(_label, item) = field
  item
}
