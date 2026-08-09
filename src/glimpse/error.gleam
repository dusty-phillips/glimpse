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
  /// Raised when a source module imports a module that is only available as a
  /// development dependency.
  SrcImportingDevDependency(module_name: String)
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
  /// Raised when a case clause guard uses syntax that is not part of the
  /// restricted guard grammar (e.g. function calls, pipelines, `case`).
  InvalidGuardExpression
  /// Raised when a pattern names a variable `true` or `false`, which is
  /// almost certainly a mistake for the `True`/`False` constructors.
  LowercaseBoolPattern(name: String)
  /// Raised when a function parameter is missing a type annotation
  MissingParameterAnnotation(name: String)
  /// Raised when `use` syntax is used with an unsupported number of subjects
  InvalidUse(subject_count: Int)
  /// Raised when a `case` (or `let`/`use`) pattern does not cover every
  /// possible shape of its subject type.
  InexhaustivePattern(description: String)
  /// Raised when a bit-array segment mixes options from different families
  /// (e.g. conflicting sizes, units, or signedness/endianness duplicates).
  InvalidBitStringSegment(mismatch: String)
  /// Raised when a `..` record update is unsafe because the spread value's
  /// variant is open or its type parameters would change.
  UnsafeRecordUpdate(name: String)
  /// Raised when a record update lists a field more than once.
  DuplicateArgument(field: String)
  /// Raised when a field access is attempted on a label that is not present on
  /// every variant (or is at a different position across variants).
  MissingField(message: String)
  /// Raised when an anonymous function declares two parameters with the same
  /// name, or a signature declares the same label twice.
  DuplicateArgumentName(name: String)
  /// Raised when a signature places an unlabelled parameter after a labelled
  /// one.
  UnlabelledArgumentAfterLabelled
  /// Raised when a function call passes a positional argument after a labelled
  /// one.
  PositionalArgumentAfterLabelled
  /// Raised when a custom type defines two constructors with the same name.
  DuplicateConstructor(name: String)
  /// Raised when a private type (or value) appears in a public interface.
  PrivateTypeLeak(name: String)
  /// Raised when `todo` is used in a module constant value.
  TodoInConstant
  /// Raised when a type alias declares a type parameter it never uses.
  UnusedTypeParameter(name: String)
  /// Raised when a constructor pattern lists every field yet also uses `..`.
  UnnecessarySpread
  /// Raised when a constructor pattern names the wrong number of fields, e.g.
  /// `Some(x)` matched against a two-field constructor.
  InvalidPatternArity(expected: Int, got: Int)
  /// Raised when a bit-string pattern assigns a variable twice, e.g.
  /// `<<a as b>>`.
  DoubleVariableAssignment
  /// Raised when a module defines two functions, two constants, or a function
  /// and a constant with the same name.
  DuplicateDefinition(name: String)
  /// Raised when a custom type or type alias declares the same type parameter
  /// name twice.
  DuplicateTypeParameter(name: String)
  /// Raised when a constructor declares two fields with the same label.
  DuplicateLabel(label: String)
  /// Raised when a type that takes no parameters is written with an argument
  /// list, e.g. `-> Int()`.
  TypeUsedAsConstructor(type_name: String)
  /// Raised when a custom type has an `@external` annotation yet declares
  /// constructors.
  ExternalTypeWithConstructors(type_name: String)
  /// Raised when a case clause lists a different number of patterns than the
  /// case has subjects.
  IncorrectPatternCount(patterns: Int, subjects: Int)
  /// Raised when a pattern binds the same variable twice, or when a variable
  /// is bound to different positions by the alternatives of a clause.
  DuplicatePatternVariable(name: String)
  /// Raised when a variable bound by one or-alternative of a clause is not
  /// bound by the other alternatives.
  MissingPatternVariable(name: String)
  /// Raised when a variable is bound by an or-alternative of a clause but not
  /// by the alternative that came before it.
  ExtraPatternVariable(name: String)
  /// Raised when a value's type is defined in terms of itself.
  RecursiveType
  /// Raised when a float literal is too large to be represented.
  FloatOutOfRange(value: String)
  /// Raised when a string literal contains an invalid escape sequence, e.g.
  /// `"\1"`, which the Gleam compiler rejects at parse time.
  InvalidEscape(value: String)
  /// Raised when an `@external` attribute names a build target that does not
  /// exist, e.g. `@external(rust, ...)`. The Gleam compiler rejects this at
  /// parse time.
  UnknownExternalTarget(name: String)
  /// Raised when an attribute is not a recognised Gleam attribute, e.g.
  /// `@deprecated__zzz(...)`. The only valid attributes are `@external`,
  /// `@internal`, `@deprecated` and `@target`; the compiler rejects anything
  /// else at parse time.
  UnknownAttribute(name: String)
  /// Raised when a value is only implemented for another build target.
  UnsupportedTarget(name: String)
  /// Raised when two imports resolve to the same local module name.
  DuplicateImport(name: String)
}

pub type TypeCheckResult(a) =
  Result(a, TypeCheckError)

pub type TypeCheckFold(a) =
  list.ContinueOrStop(TypeCheckResult(a))
