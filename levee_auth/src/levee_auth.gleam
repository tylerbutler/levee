//// Levee Authentication Library
////
//// Provides password hashing, JWT token management, user/tenant management,
//// and authorization for the Levee collaborative document service.
////
//// ## Modules
////
//// - `password` - Argon2id password hashing and verification
//// - `token` - JWT creation and verification for document access
//// - `scopes` - Authorization scope definitions
//// - `user` - User management and profile operations
//// - `tenant` - Multi-tenant organization management
//// - `session` - User session lifecycle
//// - `invite` - Tenant invitation management
////
//// ## Example Usage
////
//// ```gleam
//// import levee_auth
//// import password
//// import token
//// import scopes
//// import user
//// import tenant
//// import session
////
//// // Create a user
//// let assert Ok(new_user) = user.create(
////   email: "jane@example.com",
////   password: "secure_password",
////   display_name: "Jane Doe",
//// )
////
//// // Create a tenant (user becomes owner)
//// let assert Ok(#(new_tenant, membership)) = tenant.create(
////   name: "Acme Corp",
////   slug: "acme-corp",
////   owner_id: new_user.id,
//// )
////
//// // Create a session
//// let new_session = session.create(
////   user_id: new_user.id,
////   tenant_id: new_tenant.id,
//// )
////
//// // Create a document access token
//// let config = token.default_config("my-secret-key")
//// let jwt = token.create_document_token(
////   new_user.id,
////   new_tenant.id,
////   "doc-789",
////   scopes.read_write(),
////   config,
//// )
//// ```

import invite.{
  type Invite, type InviteConfig, type InviteError, type InviteStatus,
}
import password
import scopes.{type Scope}
import session.{type Session, type SessionConfig}
import tenant.{type Membership, type Role, type Tenant}
import token.{type TokenClaims, type TokenConfig, type TokenError}
import user.{type PublicUser, type User, type UserError}

// Re-export main password functions

/// Hash a password using Argon2id with default settings.
pub fn hash_password(pwd: String) -> Result(String, password.PasswordError) {
  password.hash(pwd)
}

/// Verify a password against a hash. Returns True if they match.
pub fn verify_password(pwd: String, hash: String) -> Bool {
  password.matches(pwd, hash)
}

// Re-export main token functions

/// Create a document access token with the specified scopes.
pub fn create_document_token(
  user_id: String,
  tenant_id: String,
  document_id: String,
  requested_scopes: List(Scope),
  config: TokenConfig,
) -> String {
  token.create_document_token(
    user_id,
    tenant_id,
    document_id,
    requested_scopes,
    config,
  )
}

/// Verify a JWT token and extract its claims.
pub fn verify_token(
  jwt: String,
  secret: String,
) -> Result(TokenClaims, TokenError) {
  token.verify(jwt, secret)
}

/// Create default token configuration with 2-hour expiration.
pub fn default_token_config(secret: String) -> TokenConfig {
  token.default_config(secret)
}

/// Create short-lived token configuration (15 minutes).
pub fn short_lived_token_config(secret: String) -> TokenConfig {
  token.short_lived_config(secret)
}

// Re-export main user functions

/// Create a new user with the given credentials.
pub fn create_user(
  email: String,
  pwd: String,
  display_name: String,
) -> Result(User, UserError) {
  user.create(email: email, password: pwd, display_name: display_name)
}

/// Convert a user to public representation (no password hash).
pub fn user_to_public(u: User) -> PublicUser {
  user.to_public(u)
}

// Re-export main tenant functions

/// Create a new tenant with the given owner.
pub fn create_tenant(
  name: String,
  slug: String,
  owner_id: String,
) -> Result(#(Tenant, Membership), tenant.TenantError) {
  tenant.create(name: name, slug: slug, owner_id: owner_id)
}

/// Check if a role can manage members.
pub fn can_manage_members(role: Role) -> Bool {
  tenant.can_manage_members(role)
}

// Re-export main session functions

/// Create a new session for a user.
pub fn create_session(user_id: String, tenant_id: String) -> Session {
  session.create(user_id: user_id, tenant_id: tenant_id)
}

/// Create a session with custom configuration.
pub fn create_session_with_config(
  user_id: String,
  tenant_id: String,
  config: SessionConfig,
) -> Session {
  session.create_with_config(
    user_id: user_id,
    tenant_id: tenant_id,
    config: config,
  )
}

/// Check if a session is still valid.
pub fn is_session_valid(s: Session) -> Bool {
  session.is_valid(s)
}

/// Default session configuration (7 days).
pub fn default_session_config() -> SessionConfig {
  session.default_config()
}

// Re-export main invite functions

/// Create an invite to join a tenant.
pub fn create_invite(
  email: String,
  tenant_id: String,
  role: Role,
  invited_by: String,
) -> Result(Invite, InviteError) {
  invite.create(
    email: email,
    tenant_id: tenant_id,
    role: role,
    invited_by: invited_by,
  )
}

/// Check if an invite is still valid (pending and not expired).
pub fn is_invite_valid(inv: Invite) -> Bool {
  invite.is_valid(inv)
}

/// Default invite configuration (7 days).
pub fn default_invite_config() -> InviteConfig {
  invite.default_config()
}
