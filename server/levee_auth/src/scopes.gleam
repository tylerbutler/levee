//// Authorization scopes for Levee document access.
////
//// The `Scope` type and its wire-string conversions are sourced from signet
//// (the shared token domain — a light dependency that avoids pulling in the
//// Fluid protocol surface). This module layers Levee's role-based scope-set
//// helpers on top of that shared vocabulary.

import gleam/list
import signet/types.{DocRead, DocWrite, SummaryRead, SummaryWrite}

/// Authorization scope for document and summary access. Re-exported from
/// signet so Levee shares one canonical `Scope` vocabulary with spillway and
/// floodgate.
pub type Scope =
  types.Scope

/// Convert a scope to its wire string representation.
pub fn to_string(scope: Scope) -> String {
  types.scope_to_string(scope)
}

/// Parse a scope from its wire string representation.
pub fn from_string(s: String) -> Result(Scope, Nil) {
  types.scope_from_string(s)
}

/// Convert a list of scopes to wire strings.
pub fn list_to_strings(scopes: List(Scope)) -> List(String) {
  types.scopes_to_strings(scopes)
}

/// Parse a list of wire strings to scopes, ignoring invalid entries.
pub fn list_from_strings(strings: List(String)) -> List(Scope) {
  types.scopes_from_strings(strings)
}

/// Check if a list of scopes contains a required scope.
pub fn has_scope(scopes: List(Scope), required: Scope) -> Bool {
  list.contains(scopes, required)
}

/// Check if scopes contain all required scopes.
pub fn has_all_scopes(scopes: List(Scope), required: List(Scope)) -> Bool {
  list.all(required, fn(r) { has_scope(scopes, r) })
}

/// Check if scopes contain any of the required scopes.
pub fn has_any_scope(scopes: List(Scope), required: List(Scope)) -> Bool {
  list.any(required, fn(r) { has_scope(scopes, r) })
}

/// Scopes for read-only document access.
pub fn read_only() -> List(Scope) {
  [DocRead]
}

/// Scopes for read-write document access.
pub fn read_write() -> List(Scope) {
  [DocRead, DocWrite]
}

/// Full access scopes (document + summary read/write).
pub fn full_access() -> List(Scope) {
  [DocRead, DocWrite, SummaryRead, SummaryWrite]
}

/// Filter scopes to only include those allowed for a given role.
/// Viewers get read-only, members get read-write, admins/owners get full access.
pub fn filter_for_role(requested: List(Scope), role: String) -> List(Scope) {
  let allowed = case role {
    "owner" | "admin" -> full_access()
    "member" -> read_write()
    "viewer" -> read_only()
    _ -> []
  }

  list.filter(requested, fn(scope) { list.contains(allowed, scope) })
}
