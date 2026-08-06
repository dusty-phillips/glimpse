import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option}
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

/// The variant a custom type is known to be, if a constructor pattern refined
/// it. `option.None` means the variant is not known.
pub fn custom_type_inferred_variant(type_: Type) -> Option(Int) {
  case type_ {
    CustomType(_module, _name, _parameters, variant) -> variant
    _ -> option.None
  }
}

/// Return a copy of a custom type marked as a known specific variant.
pub fn set_custom_type_variant(type_: Type, index: Int) -> Type {
  case type_ {
    CustomType(module, name, parameters, _variant) ->
      CustomType(module, name, parameters, option.Some(index))
    _ -> type_
  }
}

pub type Type {
  NilType
  IntType
  FloatType
  StringType
  BoolType
  BitArrayType
  TupleType(elements: List(Type))
  CustomType(
    module: String,
    name: String,
    parameters: List(Type),
    /// Which variant of the type is known to be in use, when a constructor
    /// pattern has refined the type. Used to select the right field types on
    /// access (e.g. an `Attribute` record with `value: String` versus a
    /// `Property` record with `value: Json`).
    inferred_variant: Option(Int),
  )
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
  TypeStore(
    next_id: Int,
    vars: Dict(Int, TypeVar),
    /// The name of the generic variable a fresh inference variable was created
    /// for. Unannotated function parameters get tagged with their signature's
    /// generic variable name so cross-function constraints can be traced.
    var_sources: Dict(Int, String),
    /// Constraints between named generic variables recorded while checking
    /// calls to same-module functions whose signatures are still placeholders.
    /// `generic_edges[name]` lists the variables embedded inside `name`.
    generic_edges: Dict(String, List(String)),
  )
}

pub fn new_type_store() -> TypeStore {
  TypeStore(0, dict.new(), dict.new(), dict.new())
}

/// Create a fresh unbound variable tagged with the generic variable name it
/// stands for.
pub fn fresh_var_with_source(
  store: TypeStore,
  source: String,
) -> #(TypeStore, Type) {
  let #(store, type_) = fresh_var(store)
  let id = case type_ {
    Var(id) -> id
    _ -> -1
  }
  #(
    TypeStore(..store, var_sources: dict.insert(store.var_sources, id, source)),
    type_,
  )
}

/// The generic variable name a type's inference variable was created for, if
/// any, resolving through links.
pub fn var_source(store: TypeStore, type_: Type) -> Option(String) {
  case type_ {
    Var(id) -> {
      case dict.get(store.vars, id) {
        Ok(Link(linked)) -> var_source(store, linked)
        Ok(Unbound) | Error(_) ->
          case dict.get(store.var_sources, id) {
            Ok(name) -> option.Some(name)
            Error(_) -> option.None
          }
      }
    }
    _ -> option.None
  }
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
    CustomType(module, name, parameters, inferred_variant) -> {
      let #(store, parameters) =
        list.fold(parameters, #(store, []), fn(state, parameter) {
          let #(store, acc) = state
          let #(store, parameter) = resolve(store, parameter)
          #(store, [parameter, ..acc])
        })
      #(
        store,
        CustomType(module, name, list.reverse(parameters), inferred_variant),
      )
    }
    _ -> #(store, type_)
  }
}

/// Create a fresh unbound type variable.
fn fresh_type(store: TypeStore) -> #(TypeStore, Type) {
  #(
    TypeStore(
      ..store,
      next_id: store.next_id + 1,
      vars: dict.insert(store.vars, store.next_id, Unbound),
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
      list.fold(list.repeat(Nil, count), #(store, []), fn(state, _) {
        let #(store, acc) = state
        let #(store, var) = fresh_var(store)
        #(store, [var, ..acc])
      })
      |> fn(state) { #(state.0, list.reverse(state.1)) }
  }
}

/// If `type_` is a type variable bound to a tuple that is too short for the
/// given `index`, grow the tuple to `index + 1` elements (filling with fresh
/// variables) and relink the variable, then return the element at `index`. This
/// lets several indices be accessed on the same inferred tuple. Returns
/// `Error(Nil)` if `type_` is not a type variable bound to a tuple.
pub fn extend_tuple(
  store: TypeStore,
  type_: Type,
  index: Int,
) -> Result(#(TypeStore, Type), Nil) {
  case type_ {
    Var(id) -> {
      let #(store, resolved) = resolve(store, Var(id))
      case resolved {
        TupleType(elements) -> {
          case list.drop(elements, up_to: index) |> list.first {
            Ok(element) -> Ok(#(store, element))
            Error(_) -> {
              let missing = index + 1 - list.length(elements)
              let #(store, new_elements) = fresh_vars(store, missing)
              let extended_elements = list.append(elements, new_elements)
              let extended = TupleType(extended_elements)
              let element =
                list.drop(extended_elements, up_to: index)
                |> list.first
                |> result.unwrap(GenericTypeVariable("todo"))
              Ok(#(
                TypeStore(
                  ..store,
                  vars: dict.insert(store.vars, id, Link(extended)),
                ),
                element,
              ))
            }
          }
        }
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
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
    CustomType(module, name, parameters, inferred_variant) -> {
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
        CustomType(module, name, list.reverse(parameters), inferred_variant),
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
    CustomType(_module, _name, parameters, _) ->
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

  case left, right {
    Var(lid), Var(rid) if lid == rid -> Ok(store)
    Var(id), _ -> {
      case occurs_check(store, id, right) {
        True ->
          Error(error.InvalidType(
            to_string(environment, Var(id)),
            to_string(environment, right),
            "type variable would be infinitely recursive",
          ))
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
    CustomType(lm, ln, lp, _), CustomType(rm, rn, rp, _)
      if lm == rm && ln == rn
    -> {
      unify_list_of_types(store, environment, lp, rp)
    }
    CustomType(_, _, _, _), CustomType(_, _, _, _) -> {
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
    CustomType(module, name, parameters, inferred_variant) -> {
      let #(store, names, parameters) =
        list.fold(parameters, #(store, names, []), fn(state, parameter) {
          let #(store, names, acc) = state
          let #(store, names, parameter) =
            do_generalise(store, names, parameter)
          #(store, names, [parameter, ..acc])
        })
      #(
        store,
        names,
        CustomType(module, name, list.reverse(parameters), inferred_variant),
      )
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
    // During the first function-body pass, same-module callees defined earlier
    // in source order still carry `InferredReturn` placeholders. Type-directed
    // lookups on such unknown types defer instead of erroring; the second pass
    // re-checks them against the final signatures.
    defer_unknown: Bool,
    // Constraints between named generic variables, accumulated across the
    // first function-body pass from calls to placeholder signatures. A cycle
    // means a value's type is defined in terms of itself.
    generic_edges: dict.Dict(String, List(String)),
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
    CustomType(m, n, p, _) -> m <> "." <> n <> "(" <> raw_show_list(p) <> ")"
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
    defer_unknown: False,
    generic_edges: dict.new(),
  )
}

/// Toggle whether type-directed lookups on still-unknown types defer instead of
/// erroring. Set during the first function-body pass.
pub fn set_defer_unknown(environment: Environment, defer: Bool) -> Environment {
  Environment(..environment, defer_unknown: defer)
}

/// Start a function body's store carrying the module's accumulated generic
/// variable constraints, so edges recorded in earlier bodies are visible.
pub fn seed_generic_edges(
  store: TypeStore,
  environment: Environment,
) -> TypeStore {
  TypeStore(..store, generic_edges: environment.generic_edges)
}

/// Merge a body's generic constraints back into the environment.
pub fn flush_generic_edges(
  environment: Environment,
  store: TypeStore,
) -> Environment {
  Environment(..environment, generic_edges: store.generic_edges)
}

/// Record that the named generic variable `from` embeds the given variables,
/// rejecting the constraint when it closes a cycle (the type is recursive).
pub fn record_generic_edge(
  store: TypeStore,
  from: String,
  embedded: List(String),
) -> Result(TypeStore, error.TypeCheckError) {
  let existing =
    dict.get(store.generic_edges, from)
    |> result.unwrap([])
  let merged = list.unique(list.append(existing, embedded))
  case list.any(merged, fn(name) { reaches(store.generic_edges, name, from) }) {
    True -> Error(error.RecursiveType)
    False ->
      Ok(
        TypeStore(
          ..store,
          generic_edges: dict.insert(store.generic_edges, from, merged),
        ),
      )
  }
}

/// Whether `target` is reachable from `start` following the constraint edges.
fn reaches(
  edges: dict.Dict(String, List(String)),
  start: String,
  target: String,
) -> Bool {
  let next = dict.get(edges, start) |> result.unwrap([])
  case list.contains(next, target) {
    True -> True
    False ->
      list.any(next, fn(name) { name != start && reaches(edges, name, target) })
  }
}

/// The named generic variables embedded in a type.
pub fn named_vars_in(type_: Type) -> List(String) {
  case type_ {
    GenericTypeVariable(name) -> [name]
    Var(_) -> []
    CustomType(_, _, parameters, _) ->
      parameters |> list.map(named_vars_in) |> list.flatten
    TupleType(elements) -> elements |> list.map(named_vars_in) |> list.flatten
    CallableType(parameters, _, return) ->
      list.append(
        parameters |> list.map(named_vars_in) |> list.flatten,
        named_vars_in(return),
      )
    GenericCallableType(parameters, _, return, _) ->
      list.append(
        parameters |> list.map(named_vars_in) |> list.flatten,
        named_vars_in(return),
      )
    TypeAlias(_, aliased) -> named_vars_in(aliased)
    _ -> []
  }
}

/// The named generic variables embedded in a type, including the names of
/// inference variables that were created for a generic variable.
pub fn named_vars_including_sources(
  store: TypeStore,
  type_: Type,
) -> List(String) {
  let direct = named_vars_in(type_)
  let sourced = case type_ {
    Var(id) ->
      case dict.get(store.var_sources, id) {
        Ok(name) -> [name]
        Error(_) -> []
      }
    _ -> []
  }
  list.unique(list.append(direct, sourced))
}

/// The prelude custom types that exist in every module's scope without an
/// explicit definition, e.g. `UtfCodepoint`.
fn prelude_custom_types() -> dict.Dict(String, Type) {
  let list =
    CustomType("gleam", "List", [GenericTypeVariable("a")], option.None)
  let result =
    CustomType(
      "gleam",
      "Result",
      [
        GenericTypeVariable("a"),
        GenericTypeVariable("e"),
      ],
      option.None,
    )
  dict.from_list([
    #("UtfCodepoint", CustomType("prelude", "UtfCodepoint", [], option.None)),
    #(
      "UtfCodepointLabel",
      CustomType("prelude", "UtfCodepointLabel", [], option.None),
    ),
    #("List", list),
    #("Result", result),
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
  let utf_codepoint = CustomType("prelude", "UtfCodepoint", [], option.None)
  let utf_codepoint_label =
    CustomType("prelude", "UtfCodepointLabel", [], option.None)
  dict.from_list([
    #("True", BoolType),
    #("False", BoolType),
    #("Nil", NilType),
    #(
      "Ok",
      GenericCallableType(
        [value],
        dict.new(),
        CustomType("gleam", "Result", [value, error], option.None),
        dummy_function,
      ),
    ),
    #(
      "Error",
      GenericCallableType(
        [error],
        dict.new(),
        CustomType("gleam", "Result", [value, error], option.None),
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
        option.None,
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
  use result <- result.try(do_type_(
    environment,
    new_type_store(),
    0,
    RejectHoles,
    glance_type,
  ))
  let #(_, _, type_) = result
  Ok(type_)
}

/// Like `type_`, but with a store available so that `_` holes become fresh
/// unbound inference variables (which unify with anything) rather than an
/// error. Used when converting annotations in function bodies.
pub fn type_with_store(
  environment: Environment,
  store: TypeStore,
  glance_type: glance.Type,
) -> error.TypeCheckResult(#(TypeStore, Type)) {
  use result <- result.try(do_type_(
    environment,
    store,
    0,
    FreshVars,
    glance_type,
  ))
  let #(store, _, type_) = result
  Ok(#(store, type_))
}

/// Like `type_`, but converts `_` holes into fresh named generic type
/// variables. Used in the store-less signature pass, where holes behave like
/// the compiler's unbound signature variables: distinct per hole and
/// instantiated fresh at each call site. Returns the next hole index so holes
/// in subsequent annotations stay distinct.
pub fn type_with_holes(
  environment: Environment,
  next_hole: Int,
  glance_type: glance.Type,
) -> Result(#(Int, Type), error.TypeCheckError) {
  use result <- result.try(do_type_(
    environment,
    new_type_store(),
    next_hole,
    NamedHole,
    glance_type,
  ))
  let #(_, next_hole, type_) = result
  Ok(#(next_hole, type_))
}

type HoleMode {
  RejectHoles
  FreshVars
  NamedHole
}

/// Whether a type annotation like `Int()` was written with an empty argument
/// list. `Int` and `Int()` parse to the same AST node, differing only in the
/// span covering the trailing parentheses.
fn type_used_as_constructor(
  span: glance.Span,
  module: option.Option(String),
  name: String,
) -> Bool {
  let written = case module {
    option.Some(module) -> module <> "." <> name
    option.None -> name
  }
  span.end - span.start > string.length(written)
}

fn do_type_(
  environment: Environment,
  store: TypeStore,
  next_hole: Int,
  mode: HoleMode,
  glance_type: glance.Type,
) -> Result(#(TypeStore, Int, Type), error.TypeCheckError) {
  case glance_type {
    glance.NamedType(span, "Int", option.None, []) ->
      case type_used_as_constructor(span, option.None, "Int") {
        True -> Error(error.TypeUsedAsConstructor("Int"))
        False -> Ok(#(store, next_hole, IntType))
      }
    glance.NamedType(span, "Float", option.None, []) ->
      case type_used_as_constructor(span, option.None, "Float") {
        True -> Error(error.TypeUsedAsConstructor("Float"))
        False -> Ok(#(store, next_hole, FloatType))
      }
    glance.NamedType(span, "Nil", option.None, []) ->
      case type_used_as_constructor(span, option.None, "Nil") {
        True -> Error(error.TypeUsedAsConstructor("Nil"))
        False -> Ok(#(store, next_hole, NilType))
      }
    glance.NamedType(span, "String", option.None, []) ->
      case type_used_as_constructor(span, option.None, "String") {
        True -> Error(error.TypeUsedAsConstructor("String"))
        False -> Ok(#(store, next_hole, StringType))
      }
    glance.NamedType(span, "Bool", option.None, []) ->
      case type_used_as_constructor(span, option.None, "Bool") {
        True -> Error(error.TypeUsedAsConstructor("Bool"))
        False -> Ok(#(store, next_hole, BoolType))
      }
    glance.NamedType(span, "BitArray", option.None, []) ->
      case type_used_as_constructor(span, option.None, "BitArray") {
        True -> Error(error.TypeUsedAsConstructor("BitArray"))
        False -> Ok(#(store, next_hole, BitArrayType))
      }

    glance.TupleType(_, elements) ->
      fold_type_parameters(environment, store, next_hole, mode, elements)
      |> result.map(fn(state) {
        let #(store, next_hole, elements) = state
        #(store, next_hole, TupleType(elements))
      })

    glance.FunctionType(_, parameters, return) -> {
      use #(store, next_hole, parameters) <- result.try(fold_type_parameters(
        environment,
        store,
        next_hole,
        mode,
        parameters,
      ))
      use #(store, next_hole, return) <- result.try(do_type_(
        environment,
        store,
        next_hole,
        mode,
        return,
      ))
      Ok(#(store, next_hole, CallableType(parameters, dict.new(), return)))
    }

    glance.NamedType(span, name, module, parameters) -> {
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
              use #(store, next_hole, parameter_types) <- result.try(
                fold_type_parameters(
                  environment,
                  store,
                  next_hole,
                  mode,
                  parameters,
                ),
              )
              let substitutions =
                dict.from_list(list.zip(alias_parameters, parameter_types))
              Ok(#(
                store,
                next_hole,
                substitute_type_variables(aliased, substitutions),
              ))
            }
          }
        CustomType(declared_module, declared_name, declared_parameters, _) ->
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
              use #(store, next_hole, parameter_types) <- result.try(
                fold_type_parameters(
                  environment,
                  store,
                  next_hole,
                  mode,
                  parameters,
                ),
              )
              Ok(#(
                store,
                next_hole,
                CustomType(
                  declared_module,
                  declared_name,
                  parameter_types,
                  option.None,
                ),
              ))
            }
          }
        _ ->
          case parameters {
            [] ->
              // `Int` and `Int()` parse to the same AST, distinguished only by
              // the span covering the empty argument list.
              case type_used_as_constructor(span, module, name) {
                True -> Error(error.TypeUsedAsConstructor(name))
                False -> Ok(#(store, next_hole, declared))
              }
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
        True -> Ok(#(store, next_hole, GenericTypeVariable(name)))
        False ->
          lookup_variable_type(environment, name)
          |> result.map(fn(type_) { #(store, next_hole, type_) })
      }
    }

    glance.HoleType(_, _) ->
      case mode {
        RejectHoles ->
          Error(error.InvalidType(
            "hole",
            "a known type",
            "holes are not supported",
          ))
        FreshVars -> {
          let #(store, var) = fresh_var(store)
          Ok(#(store, next_hole, var))
        }
        NamedHole ->
          Ok(#(
            store,
            next_hole + 1,
            GenericTypeVariable("hole" <> int.to_string(next_hole)),
          ))
      }
  }
}

fn fold_type_parameters(
  environment: Environment,
  store: TypeStore,
  next_hole: Int,
  mode: HoleMode,
  parameters: List(glance.Type),
) -> Result(#(TypeStore, Int, List(Type)), error.TypeCheckError) {
  list.try_fold(parameters, #(store, next_hole, []), fn(state, parameter) {
    let #(store, next_hole, acc) = state
    use #(store, next_hole, type_) <- result.try(do_type_(
      environment,
      store,
      next_hole,
      mode,
      parameter,
    ))
    Ok(#(store, next_hole, [type_, ..acc]))
  })
  |> result.map(fn(state) {
    let #(store, next_hole, types) = state
    #(store, next_hole, list.reverse(types))
  })
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
    CustomType(module, name, parameters, inferred_variant) ->
      CustomType(
        module,
        name,
        list.map(parameters, substitute_type_variables(_, substitutions)),
        inferred_variant,
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

fn is_prelude_module(module: String) -> Bool {
  module == "gleam" || module == "prelude"
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
    CustomType(module, name, parameters, _) ->
      case is_prelude_module(module) {
        True ->
          case parameters {
            [] -> name
            _ -> name <> "(" <> list_to_string(parameters, environment) <> ")"
          }
        False ->
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

/// Whether a type can be converted back to a glance annotation that resolves
/// in the current module: every custom type it mentions must be defined in the
/// current module, in a prelude module, or in an imported module. Inferred
/// types referencing other (transitively-reached) modules cannot be written
/// back, so callers leave such parameters/returns unannotated.
pub fn can_render(environment: Environment, type_: Type) -> Bool {
  case type_ {
    CustomType(module, _, parameters, _) ->
      list.all(parameters, can_render(environment, _))
      && is_renderable_module(environment, module)
    TupleType(elements) -> list.all(elements, can_render(environment, _))
    CallableType(parameters, _, return) ->
      list.all(parameters, can_render(environment, _))
      && can_render(environment, return)
    GenericCallableType(parameters, _, return, _) ->
      list.all(parameters, can_render(environment, _))
      && can_render(environment, return)
    TypeAlias(_, aliased) -> can_render(environment, aliased)
    _ -> True
  }
}

fn is_renderable_module(environment: Environment, module: String) -> Bool {
  module == environment.current_module
  || is_prelude_module(module)
  || dict.has_key(environment.import_names, module)
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
    CustomType(module, name, parameters, _) -> {
      let glance_parameters = list.map(parameters, to_glance(environment, _))
      case module == environment.current_module || is_prelude_module(module) {
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
