import gleeunit/should
import invite
import tenant

// Invite creation tests

pub fn create_invite_test() {
  let result =
    invite.create(
      email: "newuser@example.com",
      tenant_id: "ten_123",
      role: tenant.Member,
      invited_by: "usr_456",
    )

  should.be_ok(result)

  let assert Ok(new_invite) = result
  should.be_true(has_prefix(new_invite.id, "inv_"))
  should.equal(new_invite.email, "newuser@example.com")
  should.equal(new_invite.tenant_id, "ten_123")
  should.equal(new_invite.role, tenant.Member)
  should.equal(new_invite.invited_by, "usr_456")
  should.equal(new_invite.status, invite.Pending)
  should.be_true(new_invite.created_at > 0)
  should.be_true(new_invite.expires_at > new_invite.created_at)
  // Token should be generated
  should.be_true(string_length(new_invite.token) > 20)
}

pub fn create_invite_invalid_email_test() {
  let result =
    invite.create(
      email: "not-an-email",
      tenant_id: "ten_123",
      role: tenant.Member,
      invited_by: "usr_456",
    )

  should.be_error(result)
  should.equal(result, Error(invite.InvalidEmail))
}

pub fn create_invite_with_config_test() {
  let config = invite.InviteConfig(expires_in_seconds: 3600)
  // 1 hour

  let assert Ok(new_invite) =
    invite.create_with_config(
      email: "test@example.com",
      tenant_id: "ten_123",
      role: tenant.Admin,
      invited_by: "usr_456",
      config: config,
    )

  let duration = new_invite.expires_at - new_invite.created_at
  should.equal(duration, 3600)
}

// Validation tests

pub fn is_valid_pending_invite_test() {
  let assert Ok(new_invite) =
    invite.create(
      email: "test@example.com",
      tenant_id: "ten_123",
      role: tenant.Member,
      invited_by: "usr_456",
    )

  should.be_true(invite.is_valid(new_invite))
}

pub fn is_valid_expired_invite_test() {
  let expired =
    invite.from_db(
      id: "inv_test",
      token: "token123",
      email: "test@example.com",
      tenant_id: "ten_123",
      role: "member",
      invited_by: "usr_456",
      status: "pending",
      created_at: 1000,
      expires_at: 1001,
    )

  let assert Ok(inv) = expired
  should.be_false(invite.is_valid(inv))
}

pub fn is_valid_accepted_invite_test() {
  let assert Ok(new_invite) =
    invite.create(
      email: "test@example.com",
      tenant_id: "ten_123",
      role: tenant.Member,
      invited_by: "usr_456",
    )

  let accepted = invite.mark_accepted(new_invite)
  should.be_false(invite.is_valid(accepted))
}

pub fn is_valid_cancelled_invite_test() {
  let assert Ok(new_invite) =
    invite.create(
      email: "test@example.com",
      tenant_id: "ten_123",
      role: tenant.Member,
      invited_by: "usr_456",
    )

  let cancelled = invite.mark_cancelled(new_invite)
  should.be_false(invite.is_valid(cancelled))
}

// Status transition tests

pub fn mark_accepted_test() {
  let assert Ok(new_invite) =
    invite.create(
      email: "test@example.com",
      tenant_id: "ten_123",
      role: tenant.Member,
      invited_by: "usr_456",
    )

  let accepted = invite.mark_accepted(new_invite)

  should.equal(accepted.status, invite.Accepted)
  should.equal(accepted.id, new_invite.id)
  should.equal(accepted.email, new_invite.email)
}

pub fn mark_cancelled_test() {
  let assert Ok(new_invite) =
    invite.create(
      email: "test@example.com",
      tenant_id: "ten_123",
      role: tenant.Member,
      invited_by: "usr_456",
    )

  let cancelled = invite.mark_cancelled(new_invite)

  should.equal(cancelled.status, invite.Cancelled)
}

// Status serialization tests

pub fn status_to_string_test() {
  should.equal(invite.status_to_string(invite.Pending), "pending")
  should.equal(invite.status_to_string(invite.Accepted), "accepted")
  should.equal(invite.status_to_string(invite.Cancelled), "cancelled")
  should.equal(invite.status_to_string(invite.Expired), "expired")
}

pub fn status_from_string_test() {
  should.equal(invite.status_from_string("pending"), Ok(invite.Pending))
  should.equal(invite.status_from_string("accepted"), Ok(invite.Accepted))
  should.equal(invite.status_from_string("cancelled"), Ok(invite.Cancelled))
  should.equal(invite.status_from_string("expired"), Ok(invite.Expired))
  should.equal(invite.status_from_string("invalid"), Error(Nil))
}

// Default config test

pub fn default_config_test() {
  let config = invite.default_config()

  // Default should be 7 days
  should.equal(config.expires_in_seconds, 604_800)
}

// Helper

fn has_prefix(str: String, prefix: String) -> Bool {
  let prefix_len = string_length(prefix)
  let str_prefix = string_slice(str, 0, prefix_len)
  str_prefix == prefix
}

@external(erlang, "string", "length")
fn string_length(str: String) -> Int

@external(erlang, "string", "slice")
fn string_slice(str: String, start: Int, length: Int) -> String
