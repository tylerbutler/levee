//// Authorization scopes for Levee document access.
////
//// Scopes control what operations a token holder can perform.

import gleam/list

/// Authorization scopes for document and summary access.
pub type Scope {
  DocRead
  DocWrite
  SummaryRead
  SummaryWrite
}

/// Convert a scope to its string representation.
pub fn to_string(scope: Scope) -> String {
  case scope {
    DocRead -> "doc:read"
    DocWrite -> "doc:write"
    SummaryRead -> "summary:read"
    SummaryWrite -> "summary:write"
  }
}

/// Parse a scope from its string representation.
pub fn from_string(s: String) -> Result(Scope, Nil) {
  case s {
    "doc:read" -> Ok(DocRead)
    "doc:write" -> Ok(DocWrite)
    "summary:read" -> Ok(SummaryRead)
    "summary:write" -> Ok(SummaryWrite)
    _ -> Error(Nil)
  }
}

/// Convert a list of scopes to strings.
pub fn list_to_strings(scopes: List(Scope)) -> List(String) {
  list.map(scopes, to_string)
}

/// Parse a list of strings to scopes, ignoring invalid entries.
pub fn list_from_strings(strings: List(String)) -> List(Scope) {
  strings
  |> list.filter_map(from_string)
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
