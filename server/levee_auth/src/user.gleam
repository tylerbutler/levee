//// User management for Levee authentication.
////
//// Handles user creation, password verification, and profile updates.

import gleam/float
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import password as pwd
import youid/uuid

/// Minimum password length
const min_password_length = 8

/// A user in the system.
pub type User {
  User(
    /// Unique user identifier (usr_...)
    id: String,
    /// User's email address
    email: String,
    /// Argon2 password hash
    password_hash: String,
    /// Display name
    display_name: String,
    /// GitHub user ID (for OAuth users)
    github_id: Option(String),
    /// Unix timestamp when user was created
    created_at: Int,
    /// Unix timestamp when user was last updated
    updated_at: Int,
  )
}

/// Public user data (no password hash).
pub type PublicUser {
  PublicUser(id: String, email: String, display_name: String, created_at: Int)
}

/// Errors that can occur during user operations.
pub type UserError {
  /// Email format is invalid
  InvalidEmail
  /// Password is too short
  PasswordTooShort
  /// Current password is incorrect (for password change)
  InvalidCurrentPassword
  /// Password hashing failed
  HashingError
}

/// Create a new user.
///
/// Validates email format and password strength, hashes the password,
/// and generates a unique ID.
pub fn create(
  email email: String,
  password password: String,
  display_name display_name: String,
) -> Result(User, UserError) {
  // Validate email (basic check for @ symbol)
  use <- validate_email(email)

  // Validate password length
  use <- validate_password(password)

  // Hash password
  use password_hash <- result.try(
    pwd.hash(password)
    |> result.replace_error(HashingError),
  )

  let now = now_unix()
  let id = generate_id("usr")

  // Use display name or derive from email
  let name = case display_name {
    "" -> derive_name_from_email(email)
    name -> name
  }

  Ok(User(
    id: id,
    email: email,
    password_hash: password_hash,
    display_name: name,
    github_id: None,
    created_at: now,
    updated_at: now,
  ))
}

/// Create a new user from an OAuth provider (no password required).
pub fn create_oauth(
  email email: String,
  display_name display_name: String,
  github_id github_id: String,
) -> User {
  let now = now_unix()
  let id = generate_id("usr")

  let name = case display_name {
    "" -> derive_name_from_email(email)
    name -> name
  }

  User(
    id: id,
    email: email,
    password_hash: "",
    display_name: name,
    github_id: Some(github_id),
    created_at: now,
    updated_at: now,
  )
}

/// Verify a password against a user's stored hash.
pub fn verify_password(user: User, password: String) -> Bool {
  pwd.matches(password, user.password_hash)
}

/// Update a user's display name.
pub fn update_display_name(user: User, new_name: String) -> User {
  User(..user, display_name: new_name, updated_at: now_unix())
}

/// Change a user's password.
///
/// Requires the current password for verification.
pub fn change_password(
  user: User,
  current_password: String,
  new_password: String,
) -> Result(User, UserError) {
  // Verify current password
  case verify_password(user, current_password) {
    False -> Error(InvalidCurrentPassword)
    True -> {
      // Validate new password
      use <- validate_password(new_password)

      // Hash new password
      use new_hash <- result.try(
        pwd.hash(new_password)
        |> result.replace_error(HashingError),
      )

      Ok(User(..user, password_hash: new_hash, updated_at: now_unix()))
    }
  }
}

/// Convert a user to public representation (no password hash).
pub fn to_public(user: User) -> PublicUser {
  PublicUser(
    id: user.id,
    email: user.email,
    display_name: user.display_name,
    created_at: user.created_at,
  )
}

/// Create a User from database fields.
pub fn from_db(
  id: String,
  email: String,
  password_hash: String,
  display_name: String,
  github_id: Option(String),
  created_at: Int,
  updated_at: Int,
) -> User {
  User(
    id: id,
    email: email,
    password_hash: password_hash,
    display_name: display_name,
    github_id: github_id,
    created_at: created_at,
    updated_at: updated_at,
  )
}

// Validation helpers

fn validate_email(email: String, next: fn() -> Result(User, UserError)) {
  case string.contains(email, "@") {
    True -> next()
    False -> Error(InvalidEmail)
  }
}

fn validate_password(password: String, next: fn() -> Result(User, UserError)) {
  case string.length(password) >= min_password_length {
    True -> next()
    False -> Error(PasswordTooShort)
  }
}

fn derive_name_from_email(email: String) -> String {
  case string.split(email, "@") {
    [local, ..] -> local
    _ -> email
  }
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
