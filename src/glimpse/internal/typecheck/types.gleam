import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import glimpse/error

/// Placeholder span for synthetic AST nodes created during type inference
const unknown_span = glance.Span(-1, -1)

fn is_type_variable(name: String) -> Bool {
  string.first(name)
  |> result.map(fn(first_char) { string.lowercase(first_char) == first_char })
  |> result.unwrap(False)
}

pub type Type {
  NilType
  IntType
  FloatType
  StringType
  BoolType
  BitArrayType
  TupleType(elements: List(Type))
  ListType(element: Type)
  ResultType(ok: Type, error: Type)
  OptionType(inner: Type)
  CustomType(module: String, name: String, parameters: List(Type))
  CallableType(
    /// All parameters (labelled or otherwise)
    parameters: List(Type),
    /// Map of label to its position in parameters list
    position_labels: Dict(String, Int),
    return: Type,
  )
  GenericCallableType(
    /// All parameters (labelled or otherwise)
    parameters: List(Type),
    /// Map of label to its position in parameters list
    position_labels: Dict(String, Int),
    return: Type,
    /// Original glance function for re-typechecking
    original_function: glance.Function,
  )
  /// Used for field access on imports; no direct glance analog
  NamespaceType(
    definitions: Dict(String, Type),
    custom_types: Dict(String, Type),
  )
  /// A type alias that has not been applied to its parameters yet. The aliased
  /// type uses `GenericTypeVariable` for the parameter names; applying the alias
  /// substitutes those variables (see `type_`).
  TypeAlias(parameters: List(String), aliased: Type)
  GenericTypeVariable(name: String)
  /// An inference/instantiation variable created while checking a call. These
  /// only exist transiently during call checking and are resolved or generalised
  /// back to `GenericTypeVariable` before being stored.
  Var(id: Int)
  InferredReturn
}

/// A type variable that may or may not have been unified with another type.
pub type TypeVar {
  Unbound
  Link(Type)
}

/// Threads the state of inference variables created during call checking.
/// Stores are local to a single call and are discarded afterwards.
pub type TypeStore {
  TypeStore(next_id: Int, vars: Dict(Int, TypeVar))
}

pub fn new_type_store() -> TypeStore {
  TypeStore(0, dict.new())
}

/// Follow any `Link` chains on a type variable to its current binding. If the
/// variable is unbound (or unknown) it is returned as-is. Recurses into
/// compound types so linked variables nested inside them are resolved too.
pub fn resolve(store: TypeStore, type_: Type) -> #(TypeStore, Type) {
  case type_ {
    Var(id) -> {
      case dict.get(store.vars, id) {
        Ok(Link(type_)) -> resolve(store, type_)
        Ok(Unbound) | Error(_) -> #(store, Var(id))
      }
    }
    CallableType(parameters, labels, return) -> {
      let #(store, parameters) =
        list.fold(parameters, #(store, []), fn(state, parameter) {
          let #(store, acc) = state
          let #(store, parameter) = resolve(store, parameter)
          #(store, [parameter, ..acc])
        })
      let #(store, return) = resolve(store, return)
      #(store, CallableType(list.reverse(parameters), labels, return))
    }
    GenericCallableType(parameters, labels, return, original) -> {
      let #(store, parameters) =
        list.fold(parameters, #(store, []), fn(state, parameter) {
          let #(store, acc) = state
          let #(store, parameter) = resolve(store, parameter)
          #(store, [parameter, ..acc])
        })
      let #(store, return) = resolve(store, return)
      #(
        store,
        GenericCallableType(list.reverse(parameters), labels, return, original),
      )
    }
    TupleType(elements) -> {
      let #(store, elements) =
        list.fold(elements, #(store, []), fn(state, element) {
          let #(store, acc) = state
          let #(store, element) = resolve(store, element)
          #(store, [element, ..acc])
        })
      #(store, TupleType(list.reverse(elements)))
    }
    ListType(element) -> {
      let #(store, element) = resolve(store, element)
      #(store, ListType(element))
    }
    ResultType(ok, error) -> {
      let #(store, ok) = resolve(store, ok)
      let #(store, error) = resolve(store, error)
      #(store, ResultType(ok, error))
    }
    OptionType(inner) -> {
      let #(store, inner) = resolve(store, inner)
      #(store, OptionType(inner))
    }
    CustomType(module, name, parameters) -> {
      let #(store, parameters) =
        list.fold(parameters, #(store, []), fn(state, parameter) {
          let #(store, acc) = state
          let #(store, parameter) = resolve(store, parameter)
          #(store, [parameter, ..acc])
        })
      #(store, CustomType(module, name, list.reverse(parameters)))
    }
    _ -> #(store, type_)
  }
}

/// Create a fresh unbound type variable.
fn fresh_type(store: TypeStore) -> #(TypeStore, Type) {
  #(
    TypeStore(
      store.next_id + 1,
      dict.insert(store.vars, store.next_id, Unbound),
    ),
    Var(store.next_id),
  )
}

/// Create a fresh unbound inference variable. Used for parameters whose types
/// are inferred from their use within a function body.
pub fn fresh_var(store: TypeStore) -> #(TypeStore, Type) {
  fresh_type(store)
}

/// Create `count` fresh unbound inference variables.
pub fn fresh_vars(store: TypeStore, count: Int) -> #(TypeStore, List(Type)) {
  case count {
    0 -> #(store, [])
    _ ->
      list.fold(list.range(1, count), #(store, []), fn(state, _) {
        let #(store, acc) = state
        let #(store, var) = fresh_var(store)
        #(store, [var, ..acc])
      })
      |> fn(state) { #(state.0, list.reverse(state.1)) }
  }
}

/// Replace every `GenericTypeVariable(name)` with a fresh `Var`. Repeated
/// occurrences of the same name are replaced with the *same* variable, which
/// preserves the sharing that gives polymorphism its meaning.
pub fn instantiate(store: TypeStore, type_: Type) -> #(TypeStore, Type) {
  let #(store, _subs, type_) = do_instantiate(store, dict.new(), type_)
  #(store, type_)
}

/// Instantiate a callable type and return its parameters, labels, and return
/// type. Any generic type variables are made fresh at each call site, whether
/// the callable is explicitly polymorphic (`GenericCallableType`) or a plain
/// `CallableType` that happens to carry type variables (e.g. a function-typed
/// parameter or variant constructor).
pub fn instantiate_callable(
  store: TypeStore,
  type_: Type,
) -> #(TypeStore, List(Type), dict.Dict(String, Int), Type) {
  case type_ {
    GenericCallableType(..) -> {
      let #(store, instantiated) = instantiate(store, type_)
      case instantiated {
        GenericCallableType(parameters, labels, return, _) -> #(
          store,
          parameters,
          labels,
          return,
        )
        _ -> #(store, [], dict.new(), NilType)
      }
    }
    CallableType(..) -> {
      let #(store, instantiated) = instantiate(store, type_)
      case instantiated {
        CallableType(parameters, labels, return) -> #(
          store,
          parameters,
          labels,
          return,
        )
        _ -> #(store, [], dict.new(), NilType)
      }
    }
    _ -> #(store, [], dict.new(), NilType)
  }
}

fn do_instantiate(
  store: TypeStore,
  substitutions: dict.Dict(String, Type),
  type_: Type,
) -> #(TypeStore, dict.Dict(String, Type), Type) {
  case type_ {
    GenericTypeVariable(name) if name == "todo" -> #(store, substitutions, type_)
    GenericTypeVariable(name) -> {
      case dict.get(substitutions, name) {
        Ok(type_) -> #(store, substitutions, type_)
        Error(_) -> {
          let #(store, fresh) = fresh_type(store)
          #(store, dict.insert(substitutions, name, fresh), fresh)
        }
      }
    }
    CallableType(parameters, labels, return) -> {
      let #(store, substitutions, parameters) =
        list.fold(parameters, #(store, substitutions, []), fn(state, parameter) {
          let #(store, substitutions, acc) = state
          let #(store, substitutions, parameter) =
            do_instantiate(store, substitutions, parameter)
          #(store, substitutions, [parameter, ..acc])
        })
      let #(store, substitutions, return) =
        do_instantiate(store, substitutions, return)
      #(
        store,
        substitutions,
        CallableType(list.reverse(parameters), labels, return),
      )
    }
    GenericCallableType(parameters, labels, return, original) -> {
      let #(store, substitutions, parameters) =
        list.fold(parameters, #(store, substitutions, []), fn(state, parameter) {
          let #(store, substitutions, acc) = state
          let #(store, substitutions, parameter) =
            do_instantiate(store, substitutions, parameter)
          #(store, substitutions, [parameter, ..acc])
        })
      let #(store, substitutions, return) =
        do_instantiate(store, substitutions, return)
      #(
        store,
        substitutions,
        GenericCallableType(list.reverse(parameters), labels, return, original),
      )
    }
    NamespaceType(definitions, custom_types) -> {
      let #(store, substitutions, definitions) =
        dict.fold(
          definitions,
          #(store, substitutions, dict.new()),
          fn(state, key, value) {
            let #(store, substitutions, acc) = state
            let #(store, substitutions, value) =
              do_instantiate(store, substitutions, value)
            #(store, substitutions, dict.insert(acc, key, value))
          },
        )
      let #(store, substitutions, custom_types) =
        dict.fold(
          custom_types,
          #(store, substitutions, dict.new()),
          fn(state, key, value) {
            let #(store, substitutions, acc) = state
            let #(store, substitutions, value) =
              do_instantiate(store, substitutions, value)
            #(store, substitutions, dict.insert(acc, key, value))
          },
        )
      #(store, substitutions, NamespaceType(definitions, custom_types))
    }
    TupleType(elements) -> {
      let #(store, substitutions, elements) =
        list.fold(elements, #(store, substitutions, []), fn(state, element) {
          let #(store, substitutions, acc) = state
          let #(store, substitutions, element) =
            do_instantiate(store, substitutions, element)
          #(store, substitutions, [element, ..acc])
        })
      #(store, substitutions, TupleType(list.reverse(elements)))
    }
    ListType(element) -> {
      let #(store, substitutions, element) =
        do_instantiate(store, substitutions, element)
      #(store, substitutions, ListType(element))
    }
    ResultType(ok, error) -> {
      let #(store, substitutions, ok) = do_instantiate(store, substitutions, ok)
      let #(store, substitutions, error) =
        do_instantiate(store, substitutions, error)
      #(store, substitutions, ResultType(ok, error))
    }
    OptionType(inner) -> {
      let #(store, substitutions, inner) =
        do_instantiate(store, substitutions, inner)
      #(store, substitutions, OptionType(inner))
    }
    CustomType(module, name, parameters) -> {
      let #(store, substitutions, parameters) =
        list.fold(parameters, #(store, substitutions, []), fn(state, parameter) {
          let #(store, substitutions, acc) = state
          let #(store, substitutions, parameter) =
            do_instantiate(store, substitutions, parameter)
          #(store, substitutions, [parameter, ..acc])
        })
      #(
        store,
        substitutions,
        CustomType(module, name, list.reverse(parameters)),
      )
    }
    _ -> #(store, substitutions, type_)
  }
}

/// Check whether the variable `id` occurs within `type_`. Used to prevent
/// creating infinitely recursive types.
fn occurs_check(store: TypeStore, id: Int, type_: Type) -> Bool {
  case type_ {
    Var(other_id) -> {
      case dict.get(store.vars, other_id) {
        Ok(Link(linked)) -> occurs_check(store, id, linked)
        Ok(Unbound) | Error(_) -> other_id == id
      }
    }
    CallableType(parameters, _labels, return) ->
      list.any(parameters, occurs_check(store, id, _))
      || occurs_check(store, id, return)
    GenericCallableType(parameters, _labels, return, _) ->
      list.any(parameters, occurs_check(store, id, _))
      || occurs_check(store, id, return)
    TupleType(elements) -> list.any(elements, occurs_check(store, id, _))
    ListType(element) -> occurs_check(store, id, element)
    ResultType(ok, error) ->
      occurs_check(store, id, ok) || occurs_check(store, id, error)
    OptionType(inner) -> occurs_check(store, id, inner)
    CustomType(_module, _name, parameters) ->
      list.any(parameters, occurs_check(store, id, _))
    _ -> False
  }
}

/// Unify two types, binding variables in the store as necessary. Returns the
/// store with any new bindings applied, or an error describing the mismatch.
pub fn unify(
  store: TypeStore,
  environment: Environment,
  left: Type,
  right: Type,
) -> Result(TypeStore, error.TypeCheckError) {
  let #(store, left) = resolve(store, left)
  let #(store, right) = resolve(store, right)

  echo "UNIFY " <> raw_show(left) <> " <-> " <> raw_show(right)

  case left, right {
    Var(lid), Var(rid) if lid == rid -> Ok(store)
    Var(id), _ -> {
      case occurs_check(store, id, right) {
        True -> {
          echo "OCCURS id="
            <> int.to_string(id)
            <> " raw-left="
            <> raw_show(Var(id))
            <> " raw-right="
            <> raw_show(right)
          Error(error.InvalidType(
            to_string(environment, Var(id)),
            to_string(environment, right),
            "type variable would be infinitely recursive",
          ))
        }
        False ->
          Ok(TypeStore(..store, vars: dict.insert(store.vars, id, Link(right))))
      }
    }
    _, Var(id) -> {
      case occurs_check(store, id, left) {
        True ->
          Error(error.InvalidType(
            to_string(environment, left),
            to_string(environment, Var(id)),
            "type variable would be infinitely recursive",
          ))
        False ->
          Ok(TypeStore(..store, vars: dict.insert(store.vars, id, Link(left))))
      }
    }
    NilType, NilType
    | IntType, IntType
    | FloatType, FloatType
    | StringType, StringType
    | BoolType, BoolType
    | BitArrayType, BitArrayType
    -> Ok(store)
    TupleType(le), TupleType(re) ->
      unify_list_of_types(store, environment, le, re)
    ListType(le), ListType(re) -> unify(store, environment, le, re)
    ResultType(lo, le), ResultType(ro, re) -> {
      use store <- result.try(unify(store, environment, lo, ro))
      unify(store, environment, le, re)
    }
    OptionType(li), OptionType(ri) -> unify(store, environment, li, ri)
    CustomType(lm, ln, lp), CustomType(rm, rn, rp) if lm == rm && ln == rn -> {
      unify_list_of_types(store, environment, lp, rp)
    }
    CustomType(_, _, _), CustomType(_, _, _) -> {
      Error(mismatch_error(environment, left, right))
    }
    CallableType(lp, ll, lr), CallableType(rp, rl, rr) ->
      unify_callables(store, environment, left, right, lp, ll, lr, rp, rl, rr)
    GenericCallableType(lp, ll, lr, _), GenericCallableType(rp, rl, rr, _) ->
      unify_callables(store, environment, left, right, lp, ll, lr, rp, rl, rr)
    GenericCallableType(lp, ll, lr, _), CallableType(rp, rl, rr)
    | CallableType(lp, ll, lr), GenericCallableType(rp, rl, rr, _)
    -> unify_callables(store, environment, left, right, lp, ll, lr, rp, rl, rr)
    GenericTypeVariable("todo"), _ -> Ok(store)
    _, GenericTypeVariable("todo") -> Ok(store)
    InferredReturn, _ -> Ok(store)
    _, InferredReturn -> Ok(store)
    GenericTypeVariable(ln), GenericTypeVariable(rn) -> {
      case ln == rn {
        True -> Ok(store)
        False -> Error(mismatch_error(environment, left, right))
      }
    }
    _, _ -> Error(mismatch_error(environment, left, right))
  }
}

fn unify_list_of_types(
  store: TypeStore,
  environment: Environment,
  left: List(Type),
  right: List(Type),
) -> Result(TypeStore, error.TypeCheckError) {
  case list.length(left) == list.length(right) {
    False ->
      Error(mismatch_error(environment, TupleType(left), TupleType(right)))
    True ->
      list.zip(left, right)
      |> list.try_fold(store, fn(store, pair) {
        let #(l, r) = pair
        unify(store, environment, l, r)
      })
  }
}

fn unify_callables(
  store: TypeStore,
  environment: Environment,
  _left: Type,
  _right: Type,
  left_parameters: List(Type),
  _left_labels: dict.Dict(String, Int),
  left_return: Type,
  right_parameters: List(Type),
  _right_labels: dict.Dict(String, Int),
  right_return: Type,
) -> Result(TypeStore, error.TypeCheckError) {
  // Function types unify positionally. Argument labels are not part of the
  // type: a labelled constructor (e.g. `Todo(location:, message:)`) may be
  // passed where an unlabelled `fn(Span, Option(Expression)) -> Expression`
  // is expected, matching the real Gleam typechecker.
  list.zip(left_parameters, right_parameters)
  |> list.try_fold(store, fn(store, pair) {
    let #(l, r) = pair
    unify(store, environment, l, r)
  })
  |> result.try(fn(store) {
    unify(store, environment, left_return, right_return)
  })
}

fn mismatch_error(
  environment: Environment,
  left: Type,
  right: Type,
) -> error.TypeCheckError {
  error.InvalidType(
    to_string(environment, left),
    to_string(environment, right),
    "in type mismatch",
  )
}

/// Name an unbound variable by its order of discovery. Uses lowercase letters
/// a-z, then falls back to a numeric suffix beyond that.
fn generalise_name(index: Int) -> String {
  let alphabet = "abcdefghijklmnopqrstuvwxyz"
  case index < string.length(alphabet) {
    True ->
      alphabet
      |> string.drop_start(index)
      |> string.first
      |> result.unwrap("")
    False -> "var" <> int.to_string(index)
  }
}

/// Replace any remaining unbound `Var` nodes in a type with
/// `GenericTypeVariable` names. Unifies any linked vars through first.
pub fn generalise(store: TypeStore, type_: Type) -> Type {
  let #(_store, _names, type_) = do_generalise(store, dict.new(), type_)
  type_
}

/// Resolve a type then generalise it, replacing any remaining unbound
/// inference variables with named generic type variables.
pub fn resolve_and_generalise(
  store: TypeStore,
  type_: Type,
) -> #(TypeStore, Type) {
  let #(_, resolved) = resolve(store, type_)
  #(store, generalise(store, resolved))
}

/// Generalise multiple types together, sharing the same name mapping
/// so that the same inference variable gets the same generic name across all types.
pub fn generalise_multi(store: TypeStore, types_: List(Type)) -> List(Type) {
  let #(_store, _names, types_) = do_generalise_multi(store, dict.new(), types_)
  types_
}

fn do_generalise_multi(
  store: TypeStore,
  names: dict.Dict(Int, String),
  types_: List(Type),
) -> #(TypeStore, dict.Dict(Int, String), List(Type)) {
  let #(store, names, acc) =
    list.fold(types_, #(store, names, []), fn(state, type_) {
      let #(store, names, acc) = state
      let #(store, names, type_) = do_generalise(store, names, type_)
      #(store, names, [type_, ..acc])
    })
  #(store, names, list.reverse(acc))
}

fn do_generalise(
  store: TypeStore,
  names: dict.Dict(Int, String),
  type_: Type,
) -> #(TypeStore, dict.Dict(Int, String), Type) {
  case type_ {
    Var(id) -> {
      case dict.get(store.vars, id) {
        Ok(Link(linked)) -> do_generalise(store, names, linked)
        Ok(Unbound) | Error(_) -> {
          case dict.get(names, id) {
            Ok(name) -> #(store, names, GenericTypeVariable(name))
            Error(_) -> {
              let name = generalise_name(dict.size(names))
              #(store, dict.insert(names, id, name), GenericTypeVariable(name))
            }
          }
        }
      }
    }
    CallableType(parameters, labels, return) -> {
      let #(store, names, parameters) =
        list.fold(parameters, #(store, names, []), fn(state, parameter) {
          let #(store, names, acc) = state
          let #(store, names, parameter) =
            do_generalise(store, names, parameter)
          #(store, names, [parameter, ..acc])
        })
      let #(store, names, return) = do_generalise(store, names, return)
      #(store, names, CallableType(list.reverse(parameters), labels, return))
    }
    GenericCallableType(parameters, labels, return, original) -> {
      let #(store, names, parameters) =
        list.fold(parameters, #(store, names, []), fn(state, parameter) {
          let #(store, names, acc) = state
          let #(store, names, parameter) =
            do_generalise(store, names, parameter)
          #(store, names, [parameter, ..acc])
        })
      let #(store, names, return) = do_generalise(store, names, return)
      #(
        store,
        names,
        GenericCallableType(list.reverse(parameters), labels, return, original),
      )
    }
    TupleType(elements) -> {
      let #(store, names, elements) =
        list.fold(elements, #(store, names, []), fn(state, element) {
          let #(store, names, acc) = state
          let #(store, names, element) = do_generalise(store, names, element)
          #(store, names, [element, ..acc])
        })
      #(store, names, TupleType(list.reverse(elements)))
    }
    ListType(element) -> {
      let #(store, names, element) = do_generalise(store, names, element)
      #(store, names, ListType(element))
    }
    ResultType(ok, error) -> {
      let #(store, names, ok) = do_generalise(store, names, ok)
      let #(store, names, error) = do_generalise(store, names, error)
      #(store, names, ResultType(ok, error))
    }
    OptionType(inner) -> {
      let #(store, names, inner) = do_generalise(store, names, inner)
      #(store, names, OptionType(inner))
    }
    CustomType(module, name, parameters) -> {
      let #(store, names, parameters) =
        list.fold(parameters, #(store, names, []), fn(state, parameter) {
          let #(store, names, acc) = state
          let #(store, names, parameter) =
            do_generalise(store, names, parameter)
          #(store, names, [parameter, ..acc])
        })
      #(store, names, CustomType(module, name, list.reverse(parameters)))
    }
    _ -> #(store, names, type_)
  }
}

pub type TypeResult =
  error.TypeCheckResult(Type)

pub type Environment {
  Environment(
    // Full absolute path. Used to identify and construct custom types
    current_module: String,
    definitions: dict.Dict(String, Type),
    public_definitions: set.Set(String),
    custom_types: dict.Dict(String, Type),
    public_custom_types: set.Set(String),
    // absolute path to whatever the relative name is in this env
    import_names: dict.Dict(String, String),
    // imported module namespaces keyed by their local alias. Kept separate
    // from `definitions` so a value (function, constant) with the same name
    // as a module alias does not clobber the namespace.
    module_imports: dict.Dict(String, Type),
    // other environments that could be imported from this one
    // (actually imported envs will be in definitions)
    module_environments: dict.Dict(String, Environment),
  )
}

pub type EnvState(a) {
  EnvState(environment: Environment, state: a)
}

pub fn raw_show(type_: Type) -> String {
  case type_ {
    Var(id) -> "V" <> int.to_string(id)
    NilType -> "Nil"
    IntType -> "Int"
    FloatType -> "Float"
    StringType -> "String"
    BoolType -> "Bool"
    BitArrayType -> "BitArray"
    TupleType(e) -> "#(" <> raw_show_list(e) <> ")"
    ListType(e) -> "List(" <> raw_show(e) <> ")"
    ResultType(o, e) -> "Result(" <> raw_show(o) <> "," <> raw_show(e) <> ")"
    OptionType(i) -> "Option(" <> raw_show(i) <> ")"
    CustomType(m, n, p) -> m <> "." <> n <> "(" <> raw_show_list(p) <> ")"
    CallableType(p, _, r) ->
      "Callable(" <> raw_show_list(p) <> " -> " <> raw_show(r) <> ")"
    GenericCallableType(p, _, r, _) ->
      "GenCallable(" <> raw_show_list(p) <> " -> " <> raw_show(r) <> ")"
    NamespaceType(_, _) -> "Namespace"
    TypeAlias(_, aliased) -> "Alias(" <> raw_show(aliased) <> ")"
    GenericTypeVariable(n) -> "G:" <> n
    InferredReturn -> "InferredReturn"
  }
}

pub fn raw_show_list(types_: List(Type)) -> String {
  types_
  |> list.map(raw_show)
  |> string.join(", ")
}

pub type EnvStateResult(a) =
  error.TypeCheckResult(EnvState(a))

pub type EnvStateFold(a) =
  error.TypeCheckFold(EnvState(a))

pub type TypeState =
  EnvState(Type)

pub type TypeStateFold =
  error.TypeCheckFold(TypeState)

pub type TypeStateResult =
  error.TypeCheckResult(TypeState)

pub type EnvironmentResult =
  error.TypeCheckResult(Environment)

pub type EnvironmentFold =
  error.TypeCheckFold(Environment)

pub fn new_env(current_module: String) -> Environment {
  Environment(
    current_module:,
    definitions: prelude_definitions(),
    public_definitions: set.new(),
    custom_types: prelude_custom_types(),
    public_custom_types: set.new(),
    import_names: dict.new(),
    module_imports: dict.new(),
    module_environments: dict.new(),
  )
}

/// The prelude custom types that exist in every module's scope without an
/// explicit definition, e.g. `UtfCodepoint`.
fn prelude_custom_types() -> dict.Dict(String, Type) {
  dict.from_list([
    #("UtfCodepoint", CustomType("prelude", "UtfCodepoint", [])),
    #("UtfCodepointLabel", CustomType("prelude", "UtfCodepointLabel", [])),
  ])
}

/// The values made available in every module without an explicit import, mirroring
/// the prelude that the Gleam compiler seeds into each module's scope. Only values
/// are registered; prelude type names are handled specially in `type_`.
fn prelude_definitions() -> dict.Dict(String, Type) {
  // Sentinel matching `functions.dummy_function`, used as the `original_function`
  // for generic callables. Constructed inline to avoid a circular import.
  let dummy_function =
    glance.Function(
      glance.Span(-1, -1),
      "",
      glance.Private,
      [],
      option.None,
      [],
    )
  let value = GenericTypeVariable("a")
  let error = GenericTypeVariable("e")
  let utf_codepoint = CustomType("prelude", "UtfCodepoint", [])
  let utf_codepoint_label = CustomType("prelude", "UtfCodepointLabel", [])
  dict.from_list([
    #("True", BoolType),
    #("False", BoolType),
    #("Nil", NilType),
    #(
      "Ok",
      GenericCallableType(
        [value],
        dict.new(),
        ResultType(value, error),
        dummy_function,
      ),
    ),
    #(
      "Error",
      GenericCallableType(
        [error],
        dict.new(),
        ResultType(value, error),
        dummy_function,
      ),
    ),
    #(
      "UtfCodepoint",
      GenericCallableType([IntType], dict.new(), utf_codepoint, dummy_function),
    ),
    #(
      "UtfCodepointLabel",
      GenericCallableType(
        [StringType],
        dict.new(),
        utf_codepoint_label,
        dummy_function,
      ),
    ),
  ])
}

pub fn add_or_update_def_in_env(
  environment: Environment,
  name: String,
  type_: Type,
) -> Environment {
  Environment(
    ..environment,
    definitions: dict.insert(environment.definitions, name, type_),
  )
}

/// publish a name that is already in the definitions so that it is
/// visible to importing modules
pub fn publish_def_in_env(
  environment: Environment,
  name: String,
) -> Environment {
  Environment(
    ..environment,
    public_definitions: set.insert(environment.public_definitions, name),
  )
}

/// publish a custom_type that is already in the custom_types so that it is
/// visible to importing modules
pub fn publish_custom_type_in_env(
  environment: Environment,
  name: String,
) -> Environment {
  Environment(
    ..environment,
    public_custom_types: set.insert(environment.public_custom_types, name),
  )
}

pub fn add_custom_type_to_env(
  environment: Environment,
  name: String,
  parameters: List(String),
) -> Environment {
  Environment(
    ..environment,
    custom_types: dict.insert(
      environment.custom_types,
      name,
      CustomType(
        environment.current_module,
        name,
        list.map(parameters, fn(parameter) { GenericTypeVariable(parameter) }),
      ),
    ),
  )
}

/// Insert a custom type under a new name, preserving its defining module and
/// type parameters. Used when importing types unqualified from another module.
pub fn add_or_update_custom_type_in_env(
  environment: Environment,
  name: String,
  type_: Type,
) -> Environment {
  Environment(
    ..environment,
    custom_types: dict.insert(environment.custom_types, name, type_),
  )
}

/// Register a module namespace under its local alias. Namespaces live in a
/// separate dict from value definitions so a function or constant sharing the
/// alias's name does not overwrite them.
pub fn add_or_update_namespace_in_env(
  environment: Environment,
  name: String,
  namespace: Type,
) -> Environment {
  Environment(
    ..environment,
    module_imports: dict.insert(environment.module_imports, name, namespace),
  )
}

pub fn add_import_mapping_to_env(
  environment: Environment,
  absolute_name: String,
  relative_name: String,
) -> Environment {
  Environment(
    ..environment,
    import_names: dict.insert(
      environment.import_names,
      absolute_name,
      relative_name,
    ),
  )
}

pub fn lookup_variable_type(
  environment: Environment,
  name: String,
) -> TypeResult {
  dict.get(environment.definitions, name)
  |> result.replace_error(error.InvalidName(name))
}

pub fn lookup_custom_type(
  environment: Environment,
  name: String,
) -> TypeResult {
  dict.get(environment.custom_types, name)
  |> result.replace_error(error.UnknownCustomType(name))
}

pub fn extract_env(state: EnvState(a)) -> Environment {
  state.environment
}

pub fn type_(environment: Environment, glance_type: glance.Type) -> TypeResult {
  case glance_type {
    glance.NamedType(_, "Int", option.None, []) -> Ok(IntType)
    glance.NamedType(_, "Float", option.None, []) -> Ok(FloatType)
    glance.NamedType(_, "Nil", option.None, []) -> Ok(NilType)
    glance.NamedType(_, "String", option.None, []) -> Ok(StringType)
    glance.NamedType(_, "Bool", option.None, []) -> Ok(BoolType)
    glance.NamedType(_, "BitArray", option.None, []) -> Ok(BitArrayType)

    glance.NamedType(_, "List", option.None, [element]) ->
      type_(environment, element) |> result.map(ListType)
    glance.NamedType(_, "Result", option.None, [ok, error]) -> {
      use ok <- result.try(type_(environment, ok))
      use error <- result.try(type_(environment, error))
      Ok(ResultType(ok, error))
    }
    glance.NamedType(_, "Option", option.None, [inner]) ->
      type_(environment, inner) |> result.map(OptionType)

    glance.TupleType(_, elements) ->
      list.try_map(elements, type_(environment, _))
      |> result.map(TupleType)

    glance.FunctionType(_, parameters, return) -> {
      use parameters <- result.try(
        list.try_map(parameters, type_(environment, _)),
      )
      use return <- result.try(type_(environment, return))
      Ok(CallableType(parameters, dict.new(), return))
    }

    glance.NamedType(_, name, module, parameters) -> {
      use declared <- result.try(lookup_named_type(environment, module, name))
      case declared {
        TypeAlias(alias_parameters, aliased) ->
          case list.length(alias_parameters) == list.length(parameters) {
            False ->
              Error(error.InvalidType(
                name,
                to_string(environment, declared),
                "wrong number of type parameters: expected "
                  <> int.to_string(list.length(alias_parameters))
                  <> ", got "
                  <> int.to_string(list.length(parameters)),
              ))
            True -> {
              use parameter_types <- result.try(
                list.try_map(parameters, type_(environment, _)),
              )
              let substitutions =
                dict.from_list(list.zip(alias_parameters, parameter_types))
              Ok(substitute_type_variables(aliased, substitutions))
            }
          }
        CustomType(declared_module, declared_name, declared_parameters) ->
          case list.length(declared_parameters) == list.length(parameters) {
            False ->
              Error(error.InvalidType(
                name,
                to_string(environment, declared),
                "wrong number of type parameters: expected "
                  <> int.to_string(list.length(declared_parameters))
                  <> ", got "
                  <> int.to_string(list.length(parameters)),
              ))
            True -> {
              use parameter_types <- result.try(
                list.try_map(parameters, type_(environment, _)),
              )
              Ok(CustomType(declared_module, declared_name, parameter_types))
            }
          }
        _ ->
          case parameters {
            [] -> Ok(declared)
            _ ->
              Error(error.InvalidType(
                name,
                to_string(environment, declared),
                "type does not take parameters",
              ))
          }
      }
    }

    glance.VariableType(_, name) -> {
      case is_type_variable(name) {
        True -> Ok(GenericTypeVariable(name))
        False -> lookup_variable_type(environment, name)
      }
    }

    glance.HoleType(_, _) ->
      Error(error.InvalidType("hole", "a known type", "holes are not supported"))
  }
}

/// Substitute the given type variables (by `GenericTypeVariable` name) with the
/// provided types throughout a type. Used to apply a type alias to its
/// parameters.
pub fn substitute_type_variables(
  type_: Type,
  substitutions: dict.Dict(String, Type),
) -> Type {
  case type_ {
    GenericTypeVariable(name) -> {
      case dict.get(substitutions, name) {
        Ok(substitute) -> substitute
        Error(_) -> type_
      }
    }
    TupleType(elements) ->
      TupleType(list.map(elements, substitute_type_variables(_, substitutions)))
    ListType(element) ->
      ListType(substitute_type_variables(element, substitutions))
    ResultType(ok, error) ->
      ResultType(
        substitute_type_variables(ok, substitutions),
        substitute_type_variables(error, substitutions),
      )
    OptionType(inner) ->
      OptionType(substitute_type_variables(inner, substitutions))
    CustomType(module, name, parameters) ->
      CustomType(
        module,
        name,
        list.map(parameters, substitute_type_variables(_, substitutions)),
      )
    CallableType(parameters, labels, return) ->
      CallableType(
        list.map(parameters, substitute_type_variables(_, substitutions)),
        labels,
        substitute_type_variables(return, substitutions),
      )
    GenericCallableType(parameters, labels, return, original) ->
      GenericCallableType(
        list.map(parameters, substitute_type_variables(_, substitutions)),
        labels,
        substitute_type_variables(return, substitutions),
        original,
      )
    TypeAlias(alias_parameters, aliased) ->
      TypeAlias(
        alias_parameters,
        substitute_type_variables(aliased, substitutions),
      )
    _ -> type_
  }
}

/// Look up the type a name refers to, either directly in the environment or
/// through an imported namespace.
fn lookup_named_type(
  environment: Environment,
  module: option.Option(String),
  name: String,
) -> TypeResult {
  case module {
    option.None -> lookup_custom_type(environment, name)
    option.Some(module_name) -> {
      case dict.get(environment.module_imports, module_name) {
        Ok(NamespaceType(_, custom_types)) ->
          dict.get(custom_types, name)
          |> result.replace_error(error.InvalidFieldAccess(module_name, name))
        _ -> Error(error.InvalidFieldAccess(module_name, name))
      }
    }
  }
}

pub fn to_string(environment: Environment, type_: Type) -> String {
  case type_ {
    NilType -> "Nil"
    IntType -> "Int"
    FloatType -> "Float"
    StringType -> "String"
    BoolType -> "Bool"
    BitArrayType -> "BitArray"
    TupleType(elements) -> "(" <> list_to_string(elements, environment) <> ")"
    ListType(element) -> "List(" <> to_string(environment, element) <> ")"
    ResultType(ok, error) ->
      "Result("
      <> to_string(environment, ok)
      <> ", "
      <> to_string(environment, error)
      <> ")"
    OptionType(inner) -> "Option(" <> to_string(environment, inner) <> ")"
    CustomType(module, name, parameters) ->
      case parameters {
        [] -> module <> "." <> name
        _ ->
          module
          <> "."
          <> name
          <> "("
          <> list_to_string(parameters, environment)
          <> ")"
      }
    CallableType(parameters, _labels, return) ->
      "fn ("
      <> list_to_string(parameters, environment)
      <> ") -> "
      <> to_string(environment, return)
    GenericCallableType(parameters, _labels, return, _) ->
      "fn ("
      <> list_to_string(parameters, environment)
      <> ") -> "
      <> to_string(environment, return)
    NamespaceType(..) -> "<Namespace>"
    TypeAlias(_, aliased) -> to_string(environment, aliased)
    GenericTypeVariable(name) -> name
    Var(id) -> "var_" <> int.to_string(id)
    InferredReturn -> ""
  }
}

pub fn list_to_string(types: List(Type), environment: Environment) -> String {
  types
  |> list.map(to_string(environment, _))
  |> string.join(", ")
}

pub fn to_glance(environment: Environment, type_: Type) -> glance.Type {
  case type_ {
    NilType -> glance.NamedType(unknown_span, "Nil", option.None, [])
    IntType -> glance.NamedType(unknown_span, "Int", option.None, [])
    FloatType -> glance.NamedType(unknown_span, "Float", option.None, [])
    StringType -> glance.NamedType(unknown_span, "String", option.None, [])
    BoolType -> glance.NamedType(unknown_span, "Bool", option.None, [])
    BitArrayType -> glance.NamedType(unknown_span, "BitArray", option.None, [])
    TupleType(elements) ->
      glance.TupleType(
        unknown_span,
        list.map(elements, to_glance(environment, _)),
      )
    ListType(element) ->
      glance.NamedType(unknown_span, "List", option.None, [
        to_glance(environment, element),
      ])
    ResultType(ok, error) ->
      glance.NamedType(unknown_span, "Result", option.None, [
        to_glance(environment, ok),
        to_glance(environment, error),
      ])
    OptionType(inner) ->
      glance.NamedType(unknown_span, "Option", option.None, [
        to_glance(environment, inner),
      ])
    CustomType(module, name, parameters) -> {
      let glance_parameters = list.map(parameters, to_glance(environment, _))
      case module == environment.current_module {
        True ->
          glance.NamedType(unknown_span, name, option.None, glance_parameters)
        False -> {
          case dict.get(environment.import_names, module) {
            Ok(relative) ->
              glance.NamedType(
                unknown_span,
                name,
                option.Some(relative),
                glance_parameters,
              )
            Error(_) -> panic as "Custom type should always have a valid module"
          }
        }
      }
    }
    CallableType(parameters, _labels, return) ->
      glance.FunctionType(
        unknown_span,
        list.map(parameters, to_glance(environment, _)),
        to_glance(environment, return),
      )
    GenericCallableType(parameters, _labels, return, _) ->
      glance.FunctionType(
        unknown_span,
        list.map(parameters, to_glance(environment, _)),
        to_glance(environment, return),
      )
    NamespaceType(..) -> panic as "Cannot convert namespace to glance"
    TypeAlias(_, aliased) -> to_glance(environment, aliased)
    GenericTypeVariable(name) -> glance.VariableType(unknown_span, name)
    Var(id) -> glance.VariableType(unknown_span, "var_" <> int.to_string(id))
    InferredReturn ->
      panic as "InferredReturn should be replaced with actual type before conversion to glance"
  }
}

pub fn to_binop_error(
  environment: Environment,
  operator: String,
  left: Type,
  right: Type,
  expected: String,
) -> TypeResult {
  Error(error.InvalidBinOp(
    operator,
    to_string(environment, left),
    to_string(environment, right),
    expected,
  ))
}
