import glance

pub type GlimpseError(a) {
  LoadError(a)
  ParseError(
    glance_error: glance.Error,
    module_name: String,
    module_content: String,
  )
  ImportError(GlimpseImportError)
}

pub type GlimpseImportError {
  CircularDependencyError(module_name: String)
  MissingImportError(module_name: String)
}

pub type TypeCheckError {
  InvalidReturnType(function_name: String, got: String, expected: String)
  InvalidName(name: String)
}
