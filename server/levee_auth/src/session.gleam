//// Session management for Levee authentication.
////
//// Handles user session lifecycle, validation, and expiration.

import gleam/float
import gleam/int
import gleam/time/timestamp
import youid/uuid

/// Default session duration: 7 days in seconds
const default_session_duration = 604_800

/// A user session.
pub type Session {
  Session(
    /// Unique session identifier (ses_...)
    id: String,
    /// User this session belongs to
    user_id: String,
    /// Tenant context for this session
    tenant_id: String,
    /// Unix timestamp when session was created
    created_at: Int,
    /// Unix timestamp when session expires
    expires_at: Int,
    /// Unix timestamp of last activity
    last_active_at: Int,
  )
}

/// Session configuration.
pub type SessionConfig {
  SessionConfig(
    /// Session lifetime in seconds
    expires_in_seconds: Int,
  )
}

/// Create a new session with default configuration.
pub fn create(user_id user_id: String, tenant_id tenant_id: String) -> Session {
  create_with_config(
    user_id: user_id,
    tenant_id: tenant_id,
    config: default_config(),
  )
}

/// Create a new session with custom configuration.
pub fn create_with_config(
  user_id user_id: String,
  tenant_id tenant_id: String,
  config config: SessionConfig,
) -> Session {
  let now = now_unix()
  Session(
    id: generate_id("ses"),
    user_id: user_id,
    tenant_id: tenant_id,
    created_at: now,
    expires_at: now + config.expires_in_seconds,
    last_active_at: now,
  )
}

/// Default session configuration (7 days).
pub fn default_config() -> SessionConfig {
  SessionConfig(expires_in_seconds: default_session_duration)
}

/// Check if a session is valid (not expired).
pub fn is_valid(session: Session) -> Bool {
  let now = now_unix()
  session.expires_at > now
}

/// Update the last activity timestamp.
pub fn touch(session: Session) -> Session {
  Session(..session, last_active_at: now_unix())
}

/// Extend the session expiration by the given number of seconds.
pub fn extend(session: Session, seconds: Int) -> Session {
  Session(..session, expires_at: session.expires_at + seconds)
}

/// Get the number of seconds until the session expires.
/// Returns 0 if already expired.
pub fn remaining_seconds(session: Session) -> Int {
  let now = now_unix()
  let remaining = session.expires_at - now
  int.max(remaining, 0)
}

/// Create a Session from database fields.
pub fn from_db(
  id id: String,
  user_id user_id: String,
  tenant_id tenant_id: String,
  created_at created_at: Int,
  expires_at expires_at: Int,
  last_active_at last_active_at: Int,
) -> Session {
  Session(
    id: id,
    user_id: user_id,
    tenant_id: tenant_id,
    created_at: created_at,
    expires_at: expires_at,
    last_active_at: last_active_at,
  )
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
