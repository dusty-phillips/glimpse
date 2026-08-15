import glance
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/set
import gleam/string
import glimpse/error
import glimpse/target

/// Placeholder span for synthetic AST nodes created during type inference
const unknown_span = glance.Span(-1, -1)

fn is_type_variable(name: String) -> Bool {
  string.first(name)
  |> result.map(fn(first_char) { string.lowercase(first_char) == first_char })
  |> result.unwrap(False)
}

/// Whether a name contains an uppercase letter, which the real compiler
/// rejects in lowercase identifiers and implicit type variables.
fn name_has_uppercase(name: String) -> Bool {
  list.any(string.to_graphemes(name), fn(ch) {
    string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", ch)
  })
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
  /// A named type variable. The `rigid` flag marks a variable introduced by the
  /// current function's declared type parameters: rigidity is part of the type
  /// itself, so any operation (instantiation, generalisation, `is_generic_type`)
  /// can tell a pinned variable from a free generic without consulting the
  /// transient type store. Stored signatures use `rigid: False` so cross-module
  /// calls instantiate them afresh.
  GenericTypeVariable(name: String, rigid: Bool)
  /// An inference/instantiation variable created while checking a call. These
  /// only exist transiently during call checking and are resolved or generalised
  /// back to `GenericTypeVariable` before being stored.
  Var(id: Int)
  /// The wildcard type of `todo` and `panic` expressions, and of functions
  /// whose return type is not yet known. Unifies with any type, so it can be
  /// used in any context.
  TodoType
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

/// The generic variable name a type's inference variable was created for. A
/// variable's own tag wins over any tag reachable through links, so tags
/// survive unification.
pub fn var_source(store: TypeStore, type_: Type) -> Option(String) {
  case type_ {
    Var(id) -> {
      case dict.get(store.var_sources, id) {
        Ok(name) -> option.Some(name)
        Error(_) ->
          case dict.get(store.vars, id) {
            Ok(Link(linked)) -> var_source(store, linked)
            Ok(Unbound) | Error(_) -> option.None
          }
      }
    }
    _ -> option.None
  }
}

/// Whether a var with the given source appears nested inside `type_` (inside a
/// constructor, tuple, or function, but not as the type itself). A return type
/// that embeds its own call's return inside a container is infinitely
/// recursive (`[f(t)]`), while one that merely *is* the call's return is not
/// (`f(x) { f(x) }`).
pub fn nested_var_has_source(
  store: TypeStore,
  type_: Type,
  source: String,
) -> Bool {
  case type_ {
    Var(_) -> False
    GenericTypeVariable(_, _)
    | IntType
    | FloatType
    | StringType
    | BoolType
    | BitArrayType
    | NilType
    | TodoType
    | InferredReturn -> False
    CustomType(_, _, parameters, _) ->
      list.any(parameters, var_has_source(store, _, source))
    TupleType(elements) -> list.any(elements, var_has_source(store, _, source))
    CallableType(parameters, _, return) ->
      list.any(parameters, var_has_source(store, _, source))
      || var_has_source(store, return, source)
    GenericCallableType(parameters, _, return, _) ->
      list.any(parameters, var_has_source(store, _, source))
      || var_has_source(store, return, source)
    TypeAlias(_, aliased) -> var_has_source(store, aliased, source)
    NamespaceType(_, _) -> False
  }
}

/// Whether a var with the given source appears anywhere in `type_`, including
/// as the type itself.
fn var_has_source(store: TypeStore, type_: Type, source: String) -> Bool {
  case var_source(store, type_) {
    option.Some(found) -> found == source
    option.None ->
      case type_ {
        CustomType(_, _, parameters, _) ->
          list.any(parameters, var_has_source(store, _, source))
        TupleType(elements) ->
          list.any(elements, var_has_source(store, _, source))
        CallableType(parameters, _, return) ->
          list.any(parameters, var_has_source(store, _, source))
          || var_has_source(store, return, source)
        GenericCallableType(parameters, _, return, _) ->
          list.any(parameters, var_has_source(store, _, source))
          || var_has_source(store, return, source)
        TypeAlias(_, aliased) -> var_has_source(store, aliased, source)
        _ -> False
      }
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

/// Resolve a type while leaving any *rigid* type variables (the `rigid:`-tagged
/// vars created for a function's declared type parameters) in place. Ordinary
/// `resolve` collapses a rigid var through its link to the named generic, which
/// lets later `instantiate` calls mistake it for an instantiable generic and
/// weaken the rigid check. Unification and binding paths use this variant so
/// the rigid var's identity survives.
pub fn resolve_keep_rigid(store: TypeStore, type_: Type) -> #(TypeStore, Type) {
  case type_ {
    Var(id) -> {
      case dict.get(store.var_sources, id) {
        Ok(source) ->
          case string.starts_with(source, "rigid:") {
            True -> #(store, Var(id))
            False -> follow_rigid(store, id)
          }
        Error(_) -> follow_rigid(store, id)
      }
    }
    CallableType(parameters, labels, return) -> {
      let #(store, parameters) =
        list.fold(parameters, #(store, []), fn(state, parameter) {
          let #(store, acc) = state
          let #(store, parameter) = resolve_keep_rigid(store, parameter)
          #(store, [parameter, ..acc])
        })
      let #(store, return) = resolve_keep_rigid(store, return)
      #(store, CallableType(list.reverse(parameters), labels, return))
    }
    GenericCallableType(parameters, labels, return, original) -> {
      let #(store, parameters) =
        list.fold(parameters, #(store, []), fn(state, parameter) {
          let #(store, acc) = state
          let #(store, parameter) = resolve_keep_rigid(store, parameter)
          #(store, [parameter, ..acc])
        })
      let #(store, return) = resolve_keep_rigid(store, return)
      #(
        store,
        GenericCallableType(list.reverse(parameters), labels, return, original),
      )
    }
    TupleType(elements) -> {
      let #(store, elements) =
        list.fold(elements, #(store, []), fn(state, element) {
          let #(store, acc) = state
          let #(store, element) = resolve_keep_rigid(store, element)
          #(store, [element, ..acc])
        })
      #(store, TupleType(list.reverse(elements)))
    }
    CustomType(module, name, parameters, inferred_variant) -> {
      let #(store, parameters) =
        list.fold(parameters, #(store, []), fn(state, parameter) {
          let #(store, acc) = state
          let #(store, parameter) = resolve_keep_rigid(store, parameter)
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

/// Follow a var's link, stopping at any rigid var reached along the way. A
/// non-rigid var linked to a rigid var resolves to the rigid var itself, not to
/// the named generic it is pinned to.
fn follow_rigid(store: TypeStore, id: Int) -> #(TypeStore, Type) {
  case dict.get(store.vars, id) {
    Ok(Link(linked)) -> resolve_keep_rigid(store, linked)
    Ok(Unbound) | Error(_) -> #(store, Var(id))
  }
}

/// Resolve a type and return the id of the var it ends at, if it is an unbound
/// type variable. Returns `None` for types that are not simple vars (literals,
/// CustomType, GenericTypeVariable, callables, etc).
pub fn resolved_var_id(store: TypeStore, type_: Type) -> Option(Int) {
  case resolve(store, type_) {
    #(_, Var(id)) -> option.Some(id)
    #(_, _) -> option.None
  }
}

/// Whether the type itself is a rigid type variable (tagged `rigid:`), as
/// opposed to merely containing one. Flexible vars linked to a rigid var also
/// report rigid through `var_source`'s link-following.
pub fn is_rigid_var(store: TypeStore, type_: Type) -> Bool {
  case var_source(store, type_) {
    option.Some(source) -> string.starts_with(source, "rigid:")
    option.None -> False
  }
}

/// The declared type parameter name a rigid var stands for (the `rigid:`
/// prefix stripped from its source tag).
pub fn rigid_var_name(store: TypeStore, type_: Type) -> String {
  case var_source(store, type_) {
    option.Some(source) ->
      case string.starts_with(source, "rigid:") {
        True -> string.drop_start(source, up_to: 6)
        False -> ""
      }
    option.None -> ""
  }
}

/// Unify a rigid type variable against another type. A rigid var can only
/// unify with its own named generic, another var of the same rigid name, or a
/// flexible var that adopts the rigid identity. It can never unify with a
/// concrete or composite type, nor with a different rigid param.
fn unify_rigid(
  store: TypeStore,
  environment: Environment,
  left: Type,
  right: Type,
) -> Result(TypeStore, error.TypeCheckError) {
  // One side is a rigid var; normalise so `left` is that side. The rigid var
  // may also be reached through a flexible var linked to it.
  case rigid_var_name(store, left) {
    "" ->
      case rigid_var_name(store, right) {
        "" -> Error(mismatch_error(environment, left, right))
        _ -> unify_rigid(store, environment, right, left)
      }
    name ->
      case right {
        Var(other_id) ->
          case is_rigid_var(store, Var(other_id)) {
            True ->
              case rigid_var_name(store, Var(other_id)) == name {
                True -> Ok(store)
                False -> Error(mismatch_error(environment, left, right))
              }
            False ->
              Ok(
                TypeStore(
                  ..store,
                  vars: dict.insert(store.vars, other_id, Link(left)),
                ),
              )
          }
        TodoType -> Ok(store)
        InferredReturn -> Ok(store)
        GenericTypeVariable(other_name, _) ->
          case other_name == name {
            True -> Ok(store)
            False -> {
              Error(mismatch_error(environment, left, right))
            }
          }
        _ -> Error(mismatch_error(environment, left, right))
      }
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

/// Link a type variable to another type in the store, returning the updated
/// store. Used to pin a declared type parameter's variable to its named
/// generic at creation, so the variable resolves to (and renders as) the
/// generic name while staying rigid during body checking.
pub fn link_var_to(store: TypeStore, type_: Type, target: Type) -> TypeStore {
  case type_ {
    Var(id) ->
      TypeStore(..store, vars: dict.insert(store.vars, id, Link(target)))
    _ -> store
  }
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

/// If `type_` is a type variable bound to a tuple, return the element at
/// `index`. Returns `Error(Nil)` if `type_` is not a type variable bound to a
/// tuple, or if the tuple is too short for the index. The real compiler
/// rejects out-of-bounds tuple indices ("Out of bounds tuple index") rather
/// than growing the tuple, so an index beyond the known arity is an error.
pub fn extend_tuple(
  store: TypeStore,
  type_: Type,
  index: Int,
) -> Result(#(TypeStore, Type), Nil) {
  case type_ {
    Var(id) -> {
      let #(store, resolved) = resolve_keep_rigid(store, Var(id))
      case resolved {
        TupleType(elements) ->
          case list.drop(elements, up_to: index) |> list.first {
            Ok(element) -> Ok(#(store, element))
            Error(_) -> Error(Nil)
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
    TodoType -> #(store, substitutions, TodoType)
    GenericTypeVariable(name, True) -> #(
      store,
      substitutions,
      GenericTypeVariable(name, True),
    )
    GenericTypeVariable(name, False) -> {
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
  let #(store, left) = resolve_keep_rigid(store, left)
  let #(store, right) = resolve_keep_rigid(store, right)

  case left, right {
    Var(lid), Var(rid) if lid == rid -> Ok(store)
    Var(id), _ -> {
      case is_rigid_var(store, Var(id)) {
        True -> unify_rigid(store, environment, Var(id), right)
        False ->
          case occurs_check(store, id, right) {
            True ->
              Error(error.InvalidType(
                to_string(environment, Var(id)),
                to_string(environment, right),
                "type variable would be infinitely recursive",
              ))
            False ->
              Ok(
                TypeStore(
                  ..store,
                  vars: dict.insert(store.vars, id, Link(right)),
                ),
              )
          }
      }
    }
    _, Var(id) -> {
      case is_rigid_var(store, Var(id)) {
        True -> unify_rigid(store, environment, left, Var(id))
        False ->
          case occurs_check(store, id, left) {
            True ->
              Error(error.InvalidType(
                to_string(environment, left),
                to_string(environment, Var(id)),
                "type variable would be infinitely recursive",
              ))
            False ->
              Ok(
                TypeStore(
                  ..store,
                  vars: dict.insert(store.vars, id, Link(left)),
                ),
              )
          }
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
    CallableType(..), CallableType(..) ->
      unify_callable_types(store, environment, left, right)
    CallableType(..), GenericCallableType(..) ->
      unify_callable_types(store, environment, left, right)
    GenericCallableType(..), CallableType(..) ->
      unify_callable_types(store, environment, left, right)
    GenericCallableType(..), GenericCallableType(..) ->
      unify_callable_types(store, environment, left, right)
    TodoType, _ -> Ok(store)
    _, TodoType -> Ok(store)
    InferredReturn, _ -> Ok(store)
    _, InferredReturn -> Ok(store)
    GenericTypeVariable(ln, _), GenericTypeVariable(rn, _) -> {
      case ln == rn {
        True -> Ok(store)
        False -> {
          Error(mismatch_error(environment, left, right))
        }
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

/// Unify a record-update base's type with the constructor's instantiated return
/// type, but only at the type-parameter positions that the update does NOT set.
/// `updated_positions` holds the indices of `constructor_return`'s CustomType
/// parameters that an updated field is expected to replace (those positions are
/// left free so the field-value unification determines them). This keeps the
/// base's parameters (e.g. rigid signature type variables) linked into the
/// result for untouched positions, so updating `App(arguments, ..)` where the
/// signature names the record `App(arguments__zzz, ..)` cannot silently unify
/// the result with `App(arguments, ..)`, while still allowing fields typed by a
/// type parameter to change it.
pub fn unify_record_update_base(
  store: TypeStore,
  environment: Environment,
  record_type: Type,
  constructor_return: Type,
  updated_positions: set.Set(Int),
) -> Result(TypeStore, error.TypeCheckError) {
  // Resolve while keeping rigid vars rigid: following a rigid var's link to its
  // named generic (as `resolve` does) would let the update's fresh constructor
  // vars link to the *generic name* instead of the rigid var, so the result
  // type would silently lose the base's rigid signature type variables and
  // unify with any same-named generic in the return annotation.
  let #(store, record_type) = resolve_keep_rigid(store, record_type)
  let #(store, constructor_return) =
    resolve_keep_rigid(store, constructor_return)
  case record_type, constructor_return {
    CustomType(_, _, record_params, _), CustomType(_, _, return_params, _) -> {
      case list.length(record_params) == list.length(return_params) {
        False ->
          Error(mismatch_error(environment, record_type, constructor_return))
        True ->
          list.index_map(return_params, fn(param, index) {
            case set.contains(updated_positions, index) {
              True -> option.None
              False ->
                case list.drop(record_params, up_to: index) |> list.first {
                  Ok(record_param) -> option.Some(#(record_param, param))
                  Error(_) -> option.None
                }
            }
          })
          |> list.fold(Ok(store), fn(acc, pair) {
            case acc, pair {
              Error(e), _ -> Error(e)
              Ok(store), option.Some(#(record_param, return_param)) ->
                unify(store, environment, record_param, return_param)
              Ok(store), option.None -> Ok(store)
            }
          })
      }
    }
    _, _ -> unify(store, environment, record_type, constructor_return)
  }
}

fn unify_callable_types(
  store: TypeStore,
  environment: Environment,
  left: Type,
  right: Type,
) -> Result(TypeStore, error.TypeCheckError) {
  // Callable types unify after instantiating both sides: a generalised callable
  // (e.g. a function capture whose type variables were named at
  // generalisation) must not be compared by generic-name equality, which would
  // reject two polymorphic functions whose variables happened to get different
  // names. Instantiating gives each side fresh variables that unify
  // structurally, matching the HM treatment of two quantified types. Rigid type
  // variables pass through instantiation untouched.
  let #(store, instantiated_left) = instantiate(store, left)
  let #(store, instantiated_right) = instantiate(store, right)
  case instantiated_left, instantiated_right {
    CallableType(lp, _ll, lr), CallableType(rp, _rl, rr)
    | GenericCallableType(lp, _ll, lr, _), GenericCallableType(rp, _rl, rr, _)
    | GenericCallableType(lp, _ll, lr, _), CallableType(rp, _rl, rr)
    | CallableType(lp, _ll, lr), GenericCallableType(rp, _rl, rr, _)
    ->
      unify_callables(
        store,
        environment,
        instantiated_left,
        instantiated_right,
        lp,
        lr,
        rp,
        rr,
      )
    _, _ -> Error(mismatch_error(environment, left, right))
  }
}

fn unify_callables(
  store: TypeStore,
  environment: Environment,
  left: Type,
  right: Type,
  left_parameters: List(Type),
  left_return: Type,
  right_parameters: List(Type),
  right_return: Type,
) -> Result(TypeStore, error.TypeCheckError) {
  // Function types unify positionally. Argument labels are not part of the
  // type: a labelled constructor (e.g. `Todo(location:, message:)`) may be
  // passed where an unlabelled `fn(Span, Option(Expression)) -> Expression`
  // is expected, matching the real Gleam typechecker.
  case list.length(left_parameters) == list.length(right_parameters) {
    False -> Error(mismatch_error(environment, left, right))
    True ->
      list.zip(left_parameters, right_parameters)
      |> list.try_fold(store, fn(store, pair) {
        let #(l, r) = pair
        unify(store, environment, l, r)
      })
      |> result.try(fn(store) {
        unify(store, environment, left_return, right_return)
      })
  }
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

/// Rename the generic variables of a generalised signature that originate from
/// *unannotated* parameters to the deterministic `t_<function>_<index>` names.
/// The signature pass registers unannotated parameters under those names, so
/// keeping them stable across re-registration lets cross-function constraint
/// recording compare callee parameter names with the argument-side names.
/// Annotated parameters keep their own names.
pub fn rename_parameter_generics(
  function_name: String,
  unannotated: List(Bool),
  generalised: List(Type),
) -> List(Type) {
  let substitutions =
    list.zip(unannotated, generalised)
    |> list.index_map(fn(pair, index) { #(index, pair) })
    |> list.fold(dict.new(), fn(substitutions, item) {
      let #(index, #(is_unannotated, type_)) = item
      case is_unannotated {
        True ->
          case type_ {
            GenericTypeVariable(name, _) ->
              dict.insert(
                substitutions,
                name,
                GenericTypeVariable(
                  "t_" <> function_name <> "_" <> int.to_string(index),
                  False,
                ),
              )
            _ -> substitutions
          }
        False -> substitutions
      }
    })
  list.map(generalised, fn(type_) {
    substitute_type_variables(type_, substitutions)
  })
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
      case is_rigid_var(store, Var(id)) {
        True -> {
          // A rigid type variable (one tagged `rigid:`, or a flexible var
          // linked to one) is not free and must not be generalised to a named
          // generic: doing so lets a use site freshen it into a fresh variable
          // and unify it with any type. Keep it as the rigid var so it retains
          // its identity (e.g. a function capture `f(x, _)` whose `x` pins the
          // remaining parameter to the enclosing function's rigid type var).
          let #(_, resolved) = resolve_keep_rigid(store, Var(id))
          #(store, names, resolved)
        }
        False ->
          case dict.get(store.vars, id) {
            Ok(Link(linked)) -> do_generalise(store, names, linked)
            Ok(Unbound) | Error(_) -> {
              case dict.get(names, id) {
                Ok(name) -> #(store, names, GenericTypeVariable(name, False))
                Error(_) -> {
                  let name = generalise_name(dict.size(names))
                  #(
                    store,
                    dict.insert(names, id, name),
                    GenericTypeVariable(name, False),
                  )
                }
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

/// Which build targets a function can run on. A function supports a target
/// when it has an `@external` implementation for it, or when its Gleam body
/// (and every function it calls, transitively) runs on that target.
pub type TargetSupport {
  TargetSupport(erlang: Bool, javascript: Bool)
}

/// A function with no external and no body-call constraints: it runs on every
/// target. This is the default for constants, constructors, parameters, and
/// anything else that is not a target-restricted function definition.
pub fn all_targets_supported() -> TargetSupport {
  TargetSupport(True, True)
}

/// A function that runs on no target: a body-less external with no
/// implementation declared for either backend.
pub fn no_targets_supported() -> TargetSupport {
  TargetSupport(False, False)
}

/// Whether a function with this support can run on `target`. Custom `Named`
/// targets are always considered supported: glimpse tracks the erlang and
/// javascript backends the real compiler builds for.
pub fn target_supports(target: target.Target, support: TargetSupport) -> Bool {
  case target {
    target.Erlang -> support.erlang
    target.Javascript -> support.javascript
    target.Named(_) -> True
  }
}

/// A named function a body invokes, used when computing target support: a bare
/// name or a namespaced `module.function` reference.
pub type CallTarget {
  Named(name: String)
  Namespaced(container: String, name: String)
}

/// The names a module exposes: its value definitions and which are public.
pub type Scope {
  Scope(
    definitions: dict.Dict(String, Type),
    public_definitions: set.Set(String),
  )
}

/// How a module reaches other modules: local aliases, imported namespaces, and
/// complete module environments.
pub type Imports {
  Imports(
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

pub type Environment {
  Environment(
    // Full absolute path. Used to identify and construct custom types
    current_module: String,
    scope: Scope,
    custom_types: dict.Dict(String, Type),
    public_custom_types: set.Set(String),
    imports: Imports,
    // During the first function-body pass, same-module callees defined earlier
    // in source order still carry `InferredReturn` placeholders. Type-directed
    // lookups on such unknown types defer instead of erroring; the second pass
    // re-checks them against the final signatures.
    defer_unknown: Bool,
    // Constraints between named generic variables, accumulated across the
    // first function-body pass from calls to placeholder signatures. A cycle
    // means a value's type is defined in terms of itself.
    generic_edges: dict.Dict(String, List(String)),
    // The rigid type variables introduced by the enclosing function's
    // signature, keyed by their declared name. Threaded into function literals
    // so a lambda annotation that names one of the enclosing function's type
    // parameters (e.g. `fn(x: a)` inside `fn f(x: a)`) reuses the same rigid
    // variable instead of creating an unrelated one.
    generic_vars: dict.Dict(String, Type),
    // The name of the function whose body is currently being typechecked, if
    // any. A recursive self-call is checked against the function's own rigid
    // type variables (monomorphic recursion) rather than a fresh instantiation,
    // so a self-call passing a different rigid type variable is rejected like
    // the real compiler rejects it.
    current_function: option.Option(String),
    // The targets the current function's body is checked against. A function
    // with an external implementation for the active target uses that external,
    // so its Gleam body is dead code on that target and references to
    // target-restricted values inside it are not enforced.
    current_function_external: TargetSupport,
    // Which targets each of this module's function definitions can run on,
    // keyed by definition name. Entries for imported (unqualified) functions
    // are merged in from their defining module's environment, and entries for
    // the module's own functions are filled in once the module's bodies are
    // checked. A name that is absent runs on every target.
    target_support: dict.Dict(String, TargetSupport),
    // The build target this module is being checked for, and whether target
    // support is enforced (the real compiler enforces it only for the package
    // being compiled, not for its dependencies).
    target: target.Target,
    check_target_support: Bool,
    // Whether the value currently being resolved is a module constant. The
    // real compiler's constant resolution does not enforce opacity for
    // qualified variant-constructor references (`const x = module.Variant`
    // is accepted even for an opaque type), while the normal expression
    // resolver rejects them.
    in_constant: Bool,
  )
}

pub type EnvState(a) {
  EnvState(environment: Environment, state: a)
}

pub type EnvStateResult(a) =
  error.TypeCheckResult(EnvState(a))

pub type EnvStateFold(a) =
  error.TypeCheckFold(EnvState(a))

pub type EnvironmentResult =
  error.TypeCheckResult(Environment)

pub type EnvironmentFold =
  error.TypeCheckFold(Environment)

pub fn new_env(current_module: String) -> Environment {
  Environment(
    current_module:,
    scope: Scope(
      definitions: prelude_definitions(),
      public_definitions: set.new(),
    ),
    custom_types: prelude_custom_types(),
    public_custom_types: set.new(),
    imports: Imports(
      import_names: dict.new(),
      module_imports: dict.new(),
      module_environments: dict.new(),
    ),
    defer_unknown: False,
    generic_edges: dict.new(),
    generic_vars: dict.new(),
    current_function: option.None,
    current_function_external: no_targets_supported(),
    target_support: dict.new(),
    target: target.Erlang,
    check_target_support: False,
    in_constant: False,
  )
}

/// The environment representing the compiler's implicit prelude module, used
/// to resolve `import gleam`. The prelude's types and values are exposed as
/// namespace members (e.g. `import gleam.{Error as Err}` brings the Result
/// constructor into scope), mirroring real Gleam.
pub fn prelude_module_env(module_name: String) -> Environment {
  let custom_types = prelude_custom_types()
  let definitions = prelude_definitions()
  Environment(
    current_module: module_name,
    scope: Scope(
      definitions: definitions,
      public_definitions: dict.keys(definitions) |> set.from_list,
    ),
    custom_types: custom_types,
    public_custom_types: dict.keys(custom_types) |> set.from_list,
    imports: Imports(
      import_names: dict.new(),
      module_imports: dict.new(),
      module_environments: dict.new(),
    ),
    defer_unknown: False,
    generic_edges: dict.new(),
    generic_vars: dict.new(),
    current_function: option.None,
    current_function_external: no_targets_supported(),
    target_support: dict.new(),
    target: target.Erlang,
    check_target_support: False,
    in_constant: False,
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
  // A variable embedding itself is trivial, not infinitely recursive.
  let merged =
    list.unique(list.append(existing, embedded))
    |> list.filter(fn(name) { name != from })
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
  fold_type([], type_, fn(acc, type_) {
    case type_ {
      GenericTypeVariable(name, _) -> [name, ..acc]
      _ -> acc
    }
  })
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
    CustomType("gleam", "List", [GenericTypeVariable("a", False)], option.None)
  let result =
    CustomType(
      "gleam",
      "Result",
      [
        GenericTypeVariable("a", False),
        GenericTypeVariable("e", False),
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
  let value = GenericTypeVariable("a", False)
  let error = GenericTypeVariable("e", False)
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
        CustomType("gleam", "Result", [value, error], option.Some(0)),
        dummy_function,
      ),
    ),
    #(
      "Error",
      GenericCallableType(
        [error],
        dict.new(),
        CustomType("gleam", "Result", [value, error], option.Some(1)),
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
    scope: Scope(
      ..environment.scope,
      definitions: dict.insert(environment.scope.definitions, name, type_),
    ),
    // Rebinding a name (a parameter, pattern variable, or local value
    // shadowing a function) ends its identity as a target-restricted function
    // definition. The imported-function entries are restored by the import
    // merge and the module's own functions by the end-of-module support
    // computation.
    target_support: dict.delete(environment.target_support, name),
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
    scope: Scope(
      ..environment.scope,
      public_definitions: set.insert(environment.scope.public_definitions, name),
    ),
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
        list.map(parameters, fn(parameter) {
          GenericTypeVariable(parameter, False)
        }),
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
    imports: Imports(
      ..environment.imports,
      module_imports: dict.insert(
        environment.imports.module_imports,
        name,
        namespace,
      ),
    ),
  )
}

pub fn add_import_mapping_to_env(
  environment: Environment,
  absolute_name: String,
  relative_name: String,
) -> Environment {
  Environment(
    ..environment,
    imports: Imports(
      ..environment.imports,
      import_names: dict.insert(
        environment.imports.import_names,
        absolute_name,
        relative_name,
      ),
    ),
  )
}

/// Record which targets a definition in this environment can run on. Missing
/// entries mean "every target".
pub fn set_target_support(
  environment: Environment,
  name: String,
  support: TargetSupport,
) -> Environment {
  Environment(
    ..environment,
    target_support: dict.insert(environment.target_support, name, support),
  )
}

/// The targets a definition can run on, defaulting to every target when it is
/// not a target-restricted function.
pub fn definition_target_support(
  environment: Environment,
  name: String,
) -> TargetSupport {
  dict.get(environment.target_support, name)
  |> result.unwrap(all_targets_supported())
}

/// The name a module is accessible under in this environment: the alias it
/// was imported with (its `import_names` entry), or its own name when it was
/// never imported.
pub fn module_access_name(
  environment: Environment,
  module_name: String,
) -> String {
  dict.get(environment.imports.import_names, module_name)
  |> result.unwrap(module_name)
}

pub fn lookup_variable_type(
  environment: Environment,
  name: String,
) -> TypeResult {
  dict.get(environment.scope.definitions, name)
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

/// Whether a glance type annotation contains a `_` hole anywhere. An explicit
/// return annotation with holes needs its resolved form written back into the
/// stored signature; without holes the annotation already matches the body.
pub fn type_contains_hole(glance_type: glance.Type) -> Bool {
  case glance_type {
    glance.NamedType(_, _, _, parameters) ->
      list.any(parameters, type_contains_hole)
    glance.TupleType(_, elements) -> list.any(elements, type_contains_hole)
    glance.FunctionType(_, parameters, return) ->
      list.any(parameters, type_contains_hole) || type_contains_hole(return)
    glance.HoleType(..) -> True
    _ -> False
  }
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
        True ->
          // An implicit type variable may not contain uppercase letters: the
          // real compiler rejects `child_dataInt` in a signature as an invalid
          // type variable name.
          case name_has_uppercase(name) {
            True -> Error(error.InvalidTypeVariableName(name))
            False -> Ok(#(store, next_hole, GenericTypeVariable(name, False)))
          }
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
            GenericTypeVariable("hole" <> int.to_string(next_hole), False),
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

/// Rebuild a type, applying a callback to each non-compound type (tuples,
/// custom types, callables, and aliases are recursed into and reconstructed).
/// Used to rewrite the leaves of a type, e.g. substituting type variables.
pub fn map_type(type_: Type, on_leaf: fn(Type) -> Type) -> Type {
  case type_ {
    TupleType(elements) -> TupleType(map_types(elements, on_leaf))
    CustomType(module, name, parameters, inferred_variant) ->
      CustomType(module, name, map_types(parameters, on_leaf), inferred_variant)
    CallableType(parameters, labels, return) ->
      CallableType(
        map_types(parameters, on_leaf),
        labels,
        map_type(return, on_leaf),
      )
    GenericCallableType(parameters, labels, return, original) ->
      GenericCallableType(
        map_types(parameters, on_leaf),
        labels,
        map_type(return, on_leaf),
        original,
      )
    TypeAlias(parameters, aliased) ->
      TypeAlias(parameters, map_type(aliased, on_leaf))
    _ -> on_leaf(type_)
  }
}

/// Convert every rigid-flagged `GenericTypeVariable(name, True)` in a type to a
/// non-rigid one. Used when a lambda's annotated parameters (rigid inside its
/// body) are resolved back into the lambda's own type, which must be
/// polymorphic and instantiable at each use site.
pub fn strip_rigidity(type_: Type) -> Type {
  map_type(type_, fn(type_) {
    case type_ {
      GenericTypeVariable(name, True) -> GenericTypeVariable(name, False)
      _ -> type_
    }
  })
}

pub fn map_types(types: List(Type), on_leaf: fn(Type) -> Type) -> List(Type) {
  list.map(types, fn(type_) { map_type(type_, on_leaf) })
}

/// Thread an accumulator through every non-compound type, recursing into the
/// same structure as `map_type`. Used to collect or combine the leaves of a
/// type without rebuilding it.
pub fn fold_type(acc: a, type_: Type, on_leaf: fn(a, Type) -> a) -> a {
  case type_ {
    TupleType(elements) -> fold_types(on_leaf(acc, type_), elements, on_leaf)
    CustomType(_, _, parameters, _) ->
      fold_types(on_leaf(acc, type_), parameters, on_leaf)
    CallableType(parameters, _, return) -> {
      let acc = fold_types(on_leaf(acc, type_), parameters, on_leaf)
      fold_type(acc, return, on_leaf)
    }
    GenericCallableType(parameters, _, return, _) -> {
      let acc = fold_types(on_leaf(acc, type_), parameters, on_leaf)
      fold_type(acc, return, on_leaf)
    }
    TypeAlias(_, aliased) -> fold_type(on_leaf(acc, type_), aliased, on_leaf)
    _ -> on_leaf(acc, type_)
  }
}

pub fn fold_types(acc: a, types: List(Type), on_leaf: fn(a, Type) -> a) -> a {
  list.fold(types, acc, fn(acc, type_) { fold_type(acc, type_, on_leaf) })
}

/// Substitute the given type variables (by `GenericTypeVariable` name) with the
/// provided types throughout a type. Used to apply a type alias to its
/// parameters.
pub fn substitute_type_variables(
  type_: Type,
  substitutions: dict.Dict(String, Type),
) -> Type {
  map_type(type_, fn(type_) {
    case type_ {
      GenericTypeVariable(name, _) ->
        dict.get(substitutions, name) |> result.unwrap(type_)
      _ -> type_
    }
  })
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
      case dict.get(environment.imports.module_imports, module_name) {
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

/// Whether a type is one of the implicit prelude types seeded into every
/// module's scope. A module may shadow these with its own declaration, so
/// duplicate-definition checks must not treat the prelude seed as a clash.
pub fn is_prelude_type(type_: Type) -> Bool {
  case type_ {
    CustomType(module, _, _, _) -> is_prelude_module(module)
    _ -> False
  }
}

/// Build the prelude `List` type over the given element type.
pub fn list_type(element: Type) -> Type {
  CustomType("gleam", "List", [element], option.None)
}

/// The element type when the type is the prelude `List`, otherwise `None`.
pub fn list_element_type(type_: Type) -> Option(Type) {
  case type_ {
    CustomType("gleam", "List", [element], _) -> option.Some(element)
    _ -> option.None
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
    GenericTypeVariable(name, _) -> name
    Var(id) -> "var_" <> int.to_string(id)
    TodoType -> "todo"
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
  fold_type(True, type_, fn(acc, type_) {
    case type_ {
      CustomType(module, _, _, _) ->
        acc && is_renderable_module(environment, module)
      _ -> acc
    }
  })
}

fn is_renderable_module(environment: Environment, module: String) -> Bool {
  module == environment.current_module
  || is_prelude_module(module)
  || dict.has_key(environment.imports.import_names, module)
}

/// Whether the custom type named `name` in the local scope is the same type as
/// `module.name` (as opposed to a different type shadowing it). Used by
/// `to_glance` to decide whether an unqualified type reference is safe to emit.
fn local_type_is_same(
  environment: Environment,
  name: String,
  module: String,
) -> Bool {
  case dict.get(environment.custom_types, name) {
    Error(_) -> True
    Ok(TypeAlias(_, _)) -> False
    Ok(CustomType(custom_module, custom_name, _, _)) ->
      custom_module == module && custom_name == name
    Ok(_) -> False
  }
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
          // An unqualified name round-trips correctly only when the local
          // scope does not shadow it with a different type (e.g. a
          // `snag.{type Result}` import while the prelude `gleam.Result` is
          // in use). Qualify the reference when the bare name would resolve
          // to something else.
          case local_type_is_same(environment, name, module) {
            True ->
              glance.NamedType(
                unknown_span,
                name,
                option.None,
                glance_parameters,
              )
            False -> {
              case dict.get(environment.imports.import_names, module) {
                Ok(relative) ->
                  glance.NamedType(
                    unknown_span,
                    name,
                    option.Some(relative),
                    glance_parameters,
                  )
                Error(_) ->
                  glance.NamedType(
                    unknown_span,
                    name,
                    option.None,
                    glance_parameters,
                  )
              }
            }
          }
        False -> {
          case dict.get(environment.imports.import_names, module) {
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
    GenericTypeVariable(name, _) -> glance.VariableType(unknown_span, name)
    Var(id) -> glance.VariableType(unknown_span, "var_" <> int.to_string(id))
    TodoType -> glance.VariableType(unknown_span, "todo")
    InferredReturn ->
      panic as "InferredReturn should be replaced with actual type before conversion to glance"
  }
}
