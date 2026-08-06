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
  TypeCheckError(TypeCheckError)
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
  /// Raised when type aliases reference each other in a cycle
  RecursiveTypeAlias(name: String)
  NotCallable(got: String)
  InvalidArguments(expected: String, actual_arguments: String)
  InvalidArgumentLabel(expected: String, got: String)
  DuplicateCustomType(name: String)
  InvalidFieldAccess(container: String, label: String)
  /// Raised when a type is used where a tuple/record/etc is required
  UnexpectedType(got: String, expected: String)
  /// Raised when an annotation on a `let` or parameter does not match the
  /// inferred type
  InvalidAnnotation(got: String, expected: String, name: String)
  /// Raised when a case expression's clauses don't all agree on their type
  CaseClauseMismatch(got: String, expected: String)
  /// Raised when a pattern expects a type that doesn't match the scrutinee
  PatternMismatch(pattern: String, expected: String, got: String)
  /// Raised when the guard of a case clause is not a Bool
  InvalidGuard(got: String)
  /// Raised when a function parameter is missing a type annotation
  MissingParameterAnnotation(name: String)
  /// Raised when `use` syntax is used with an unsupported number of subjects
  InvalidUse(subject_count: Int)
}

pub type TypeCheckResult(a) =
  Result(a, TypeCheckError)

pub type TypeCheckFold(a) =
  list.ContinueOrStop(TypeCheckResult(a))
