//// Invitation management for Levee tenant system.
////
//// Handles inviting users to join tenants with role assignments.

import gleam/bit_array
import gleam/crypto
import gleam/float
import gleam/result
import gleam/string
import gleam/time/timestamp
import tenant.{type Role}
import youid/uuid

/// Default invite duration: 7 days in seconds
const default_invite_duration = 604_800

/// A pending invitation to join a tenant.
pub type Invite {
  Invite(
    /// Unique invite identifier (inv_...)
    id: String,
    /// Secure token for accepting the invite
    token: String,
    /// Email address of the invitee
    email: String,
    /// Tenant to join
    tenant_id: String,
    /// Role to be granted upon acceptance
    role: Role,
    /// User who created the invite
    invited_by: String,
    /// Current status
    status: InviteStatus,
    /// Unix timestamp when invite was created
    created_at: Int,
    /// Unix timestamp when invite expires
    expires_at: Int,
  )
}

/// Status of an invitation.
pub type InviteStatus {
  Pending
  Accepted
  Cancelled
  Expired
}

/// Invite configuration.
pub type InviteConfig {
  InviteConfig(
    /// Invite lifetime in seconds
    expires_in_seconds: Int,
  )
}

/// Errors that can occur during invite operations.
pub type InviteError {
  /// Email format is invalid
  InvalidEmail
  /// Invite has expired
  InviteExpired
  /// Invite was already used or cancelled
  InviteNotPending
}

/// Create a new invite with default configuration.
pub fn create(
  email email: String,
  tenant_id tenant_id: String,
  role role: Role,
  invited_by invited_by: String,
) -> Result(Invite, InviteError) {
  create_with_config(
    email: email,
    tenant_id: tenant_id,
    role: role,
    invited_by: invited_by,
    config: default_config(),
  )
}

/// Create a new invite with custom configuration.
pub fn create_with_config(
  email email: String,
  tenant_id tenant_id: String,
  role role: Role,
  invited_by invited_by: String,
  config config: InviteConfig,
) -> Result(Invite, InviteError) {
  // Validate email
  case string.contains(email, "@") {
    False -> Error(InvalidEmail)
    True -> {
      let now = now_unix()
      Ok(Invite(
        id: generate_id("inv"),
        token: generate_token(),
        email: email,
        tenant_id: tenant_id,
        role: role,
        invited_by: invited_by,
        status: Pending,
        created_at: now,
        expires_at: now + config.expires_in_seconds,
      ))
    }
  }
}

/// Default invite configuration (7 days).
pub fn default_config() -> InviteConfig {
  InviteConfig(expires_in_seconds: default_invite_duration)
}

/// Check if an invite is valid (pending and not expired).
pub fn is_valid(inv: Invite) -> Bool {
  case inv.status {
    Pending -> {
      let now = now_unix()
      inv.expires_at > now
    }
    Accepted | Cancelled | Expired -> False
  }
}

/// Mark an invite as accepted.
pub fn mark_accepted(inv: Invite) -> Invite {
  Invite(..inv, status: Accepted)
}

/// Mark an invite as cancelled.
pub fn mark_cancelled(inv: Invite) -> Invite {
  Invite(..inv, status: Cancelled)
}

/// Mark an invite as expired.
pub fn mark_expired(inv: Invite) -> Invite {
  Invite(..inv, status: Expired)
}

/// Convert status to string.
pub fn status_to_string(status: InviteStatus) -> String {
  case status {
    Pending -> "pending"
    Accepted -> "accepted"
    Cancelled -> "cancelled"
    Expired -> "expired"
  }
}

/// Parse status from string.
pub fn status_from_string(s: String) -> Result(InviteStatus, Nil) {
  case s {
    "pending" -> Ok(Pending)
    "accepted" -> Ok(Accepted)
    "cancelled" -> Ok(Cancelled)
    "expired" -> Ok(Expired)
    _ -> Error(Nil)
  }
}

/// Create an Invite from database fields.
pub fn from_db(
  id id: String,
  token token: String,
  email email: String,
  tenant_id tenant_id: String,
  role role: String,
  invited_by invited_by: String,
  status status: String,
  created_at created_at: Int,
  expires_at expires_at: Int,
) -> Result(Invite, Nil) {
  use parsed_role <- result.try(tenant.role_from_string(role))
  use parsed_status <- result.try(status_from_string(status))
  Ok(Invite(
    id: id,
    token: token,
    email: email,
    tenant_id: tenant_id,
    role: parsed_role,
    invited_by: invited_by,
    status: parsed_status,
    created_at: created_at,
    expires_at: expires_at,
  ))
}

// Utility helpers

fn generate_id(prefix: String) -> String {
  let id = uuid.v4_string()
  prefix <> "_" <> id
}

fn generate_token() -> String {
  // Generate 32 random bytes and encode as hex
  let bytes = crypto.strong_random_bytes(32)
  bit_array_to_hex(bytes)
}

fn bit_array_to_hex(bits: BitArray) -> String {
  bits
  |> bit_array.base16_encode
  |> string.lowercase
}

fn now_unix() -> Int {
  timestamp.system_time()
  |> timestamp.to_unix_seconds
  |> float.round
}
