# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

- `gleam test` - Run all tests
- `gleam build` - Build the project
- `gleam format` - Format code (if available)

## Project Overview

Glimpse is a Gleam library that provides package loading and typechecking capabilities for Gleam projects. It wraps the AST produced by the `glance` library to add:

1. **Package representation** - Ability to represent and introspect a complete Gleam program (multiple interdependent modules) rather than just individual modules
2. **Cross-module typechecking** - Typechecking both within and between modules

The library is filesystem-agnostic, requiring external module loading through a loader function.

## Code Style

- Never ever add useless comments to the code. Docstrings are good, but comments that just say what the code obviously said should always be avoided.

## Core Architecture

### Main Types

- `glimpse.Package` - Represents a complete package with a name and collection of modules
- `glimpse.Module` - Wraps a `glance.Module` with additional metadata (name, dependencies)
- `glimpse/error.GlimpseError` - Comprehensive error handling for load, parse, import, and typecheck errors

### Key Modules

- `src/glimpse.gleam` - Main entry point with `load_package()` function and core types
- `src/glimpse/typecheck.gleam` - Public typechecking API with `package()`, `module()`, and `function()` functions
- `src/glimpse/internal/typecheck/` - Internal typechecking implementation:
  - `types.gleam` - Type system definitions and Environment management
  - `functions.gleam` - Function signature and parameter handling
  - `imports.gleam` - Import resolution and module environment merging
  - `fields.gleam` - Field access and record handling
- `src/glimpse/internal/import_dependencies.gleam` - Dependency sorting and circular dependency detection

### Typechecking Flow

1. **Package-level**: `typecheck.package()` sorts dependencies and processes modules in order
2. **Module-level**: `typecheck.module()` processes imports, custom types, function signatures, then function bodies
3. **Function-level**: `typecheck.function()` handles parameters, type inference, and return type validation

### Environment System

The typechecking uses an `Environment` type that tracks:
- Current module context
- Available definitions (functions, variables)
- Custom types and their visibility
- Import mappings and module environments

## Testing Structure

- Tests use `gleeunit` framework
- Main test files are in `test/` directory
- Typecheck tests are organized in `test/typecheck/` with helper utilities in `helpers.gleam`
- Test helpers provide utilities for parsing glance modules and validating typecheck results
- Use `assert actual == expected` syntax instead of gleeunit.should or let assert in unit tests. For example, to verify that a Result containing a string has a certain value, use `assert actual == Ok("hello world")`. This is a new feature introduced in gleam 1.11.

## Dependencies

- `gleam_stdlib` - Standard library
- `glance` - Gleam AST parser that this library wraps
- `gleeunit` - Testing framework (dev dependency)
- `pprint` - Pretty printing for debugging (dev dependency)

## Debugging

Use `echo` syntax for debugging instead of print statements:
```gleam
echo some_value  // Prints value with file:line context to stderr
```

## Current Status

The typechecking system is partially implemented and not yet available in public releases. The main functionality focuses on basic type inference, custom type handling, and function typechecking.