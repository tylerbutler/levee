//// Tenant management for Levee multi-tenant system.
////
//// Handles tenant creation, membership, and role-based permissions.

import gleam/float
import gleam/result
import gleam/string
import gleam/time/timestamp
import youid/uuid

/// Minimum slug length
const min_slug_length = 3

/// A tenant in the system.
pub type Tenant {
  Tenant(
    /// Unique tenant identifier (ten_...)
    id: String,
    /// Tenant display name
    name: String,
    /// URL-safe unique slug
    slug: String,
    /// Unix timestamp when tenant was created
    created_at: Int,
    /// Unix timestamp when tenant was last updated
    updated_at: Int,
  )
}

/// Role within a tenant.
pub type Role {
  Owner
  Admin
  Member
  Viewer
}

/// User membership in a tenant.
pub type Membership {
  Membership(user_id: String, tenant_id: String, role: Role, joined_at: Int)
}

/// Errors that can occur during tenant operations.
pub type TenantError {
  /// Tenant name is empty or invalid
  InvalidName
  /// Slug format is invalid
  InvalidSlug
  /// Slug is already taken
  SlugTaken
}

/// Create a new tenant with the given owner.
///
/// Returns both the tenant and the owner's membership.
pub fn create(
  name name: String,
  slug slug: String,
  owner_id owner_id: String,
) -> Result(#(Tenant, Membership), TenantError) {
  // Validate name
  case string.is_empty(string.trim(name)) {
    True -> Error(InvalidName)
    False -> {
      // Validate slug
      case is_valid_slug(slug) {
        False -> Error(InvalidSlug)
        True -> {
          let now = now_unix()
          let id = generate_id("ten")

          let new_tenant =
            Tenant(
              id: id,
              name: name,
              slug: slug,
              created_at: now,
              updated_at: now,
            )

          let owner_membership =
            Membership(
              user_id: owner_id,
              tenant_id: id,
              role: Owner,
              joined_at: now,
            )

          Ok(#(new_tenant, owner_membership))
        }
      }
    }
  }
}

/// Validate a slug format.
///
/// Valid slugs:
/// - At least 3 characters
/// - Lowercase letters, numbers, hyphens, underscores only
/// - Cannot start or end with hyphen/underscore
pub fn is_valid_slug(slug: String) -> Bool {
  let len = string.length(slug)
  case len < min_slug_length {
    True -> False
    False -> {
      let chars = string.to_graphemes(slug)
      case chars {
        [first, ..rest] -> {
          // First char must be alphanumeric
          case is_alphanumeric(first) {
            False -> False
            True -> {
              // Last char must be alphanumeric
              let last = get_last(rest, first)
              case is_alphanumeric(last) {
                False -> False
                True -> {
                  // All chars must be valid slug chars
                  all_valid_slug_chars(chars)
                }
              }
            }
          }
        }
        [] -> False
      }
    }
  }
}

fn is_alphanumeric(c: String) -> Bool {
  case c {
    "a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i" | "j" | "k" | "l" | "m" ->
      True
    "n" | "o" | "p" | "q" | "r" | "s" | "t" | "u" | "v" | "w" | "x" | "y" | "z" ->
      True
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn is_valid_slug_char(c: String) -> Bool {
  case c {
    "-" | "_" -> True
    _ -> is_alphanumeric(c)
  }
}

fn all_valid_slug_chars(chars: List(String)) -> Bool {
  case chars {
    [] -> True
    [c, ..rest] ->
      case is_valid_slug_char(c) {
        False -> False
        True -> all_valid_slug_chars(rest)
      }
  }
}

fn get_last(list: List(String), default: String) -> String {
  case list {
    [] -> default
    [x] -> x
    [_, ..rest] -> get_last(rest, default)
  }
}

/// Update a tenant's name.
pub fn update_name(t: Tenant, new_name: String) -> Tenant {
  Tenant(..t, name: new_name, updated_at: now_unix())
}

/// Create a Tenant from database fields.
pub fn from_db(
  id: String,
  name: String,
  slug: String,
  created_at: Int,
  updated_at: Int,
) -> Tenant {
  Tenant(
    id: id,
    name: name,
    slug: slug,
    created_at: created_at,
    updated_at: updated_at,
  )
}

// Role functions

/// Convert a role to its string representation.
pub fn role_to_string(role: Role) -> String {
  case role {
    Owner -> "owner"
    Admin -> "admin"
    Member -> "member"
    Viewer -> "viewer"
  }
}

/// Parse a role from its string representation.
pub fn role_from_string(s: String) -> Result(Role, Nil) {
  case s {
    "owner" -> Ok(Owner)
    "admin" -> Ok(Admin)
    "member" -> Ok(Member)
    "viewer" -> Ok(Viewer)
    _ -> Error(Nil)
  }
}

/// Check if a role can manage (invite/remove) members.
pub fn can_manage_members(role: Role) -> Bool {
  case role {
    Owner | Admin -> True
    Member | Viewer -> False
  }
}

/// Check if a role can update tenant settings.
pub fn can_update_tenant(role: Role) -> Bool {
  case role {
    Owner | Admin -> True
    Member | Viewer -> False
  }
}

/// Check if a role can delete the tenant.
pub fn can_delete_tenant(role: Role) -> Bool {
  case role {
    Owner -> True
    Admin | Member | Viewer -> False
  }
}

/// Check if a role can transfer ownership.
pub fn can_transfer_ownership(role: Role) -> Bool {
  case role {
    Owner -> True
    Admin | Member | Viewer -> False
  }
}

// Membership functions

/// Create a new membership.
pub fn create_membership(
  user_id: String,
  tenant_id: String,
  role: Role,
) -> Membership {
  Membership(
    user_id: user_id,
    tenant_id: tenant_id,
    role: role,
    joined_at: now_unix(),
  )
}

/// Update a membership's role.
pub fn update_role(m: Membership, new_role: Role) -> Membership {
  Membership(..m, role: new_role)
}

/// Create a Membership from database fields.
pub fn membership_from_db(
  user_id: String,
  tenant_id: String,
  role: String,
  joined_at: Int,
) -> Result(Membership, Nil) {
  use parsed_role <- result.try(role_from_string(role))
  Ok(Membership(
    user_id: user_id,
    tenant_id: tenant_id,
    role: parsed_role,
    joined_at: joined_at,
  ))
}

// Utility helpers

fn generate_id(prefix: String) -> String {
  let id = uuid.v4_string()
  prefix <> "_" <> id
}

fn now_unix() -> Int {
  timestamp.system_time()
  |> timestamp.to_unix_seconds
  |> float.round
}
