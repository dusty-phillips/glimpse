import glance
import gleam/list

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
  InvalidType(got: String, expected: String, message: String)
  InvalidBinOp(
    operator: String,
    left_got: String,
    right_got: String,
    expected: String,
  )
  UnknownCustomType(name: String)
  NoSuchModule(name: String)
  NotCallable(got: String)
  InvalidArguments(expected: String, actual_arguments: String)
  InvalidArgumentLabel(expected: String, got: String)
  DuplicateCustomType(name: String)
}

pub type TypeCheckResult(a) =
  Result(a, TypeCheckError)

pub type TypeCheckFold(a) =
  list.ContinueOrStop(TypeCheckResult(a))
