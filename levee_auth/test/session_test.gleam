import gleeunit/should
import session

// Session creation tests

pub fn create_session_test() {
  let new_session = session.create(user_id: "usr_123", tenant_id: "ten_456")

  should.be_true(has_prefix(new_session.id, "ses_"))
  should.equal(new_session.user_id, "usr_123")
  should.equal(new_session.tenant_id, "ten_456")
  should.be_true(new_session.created_at > 0)
  should.be_true(new_session.expires_at > new_session.created_at)
  should.equal(new_session.last_active_at, new_session.created_at)
}

pub fn create_session_with_config_test() {
  let config = session.SessionConfig(expires_in_seconds: 3600)
  // 1 hour
  let new_session =
    session.create_with_config(
      user_id: "usr_123",
      tenant_id: "ten_456",
      config: config,
    )

  // Should expire in ~1 hour
  let duration = new_session.expires_at - new_session.created_at
  should.equal(duration, 3600)
}

// Validation tests

pub fn is_valid_active_session_test() {
  let new_session = session.create(user_id: "usr_123", tenant_id: "ten_456")

  should.be_true(session.is_valid(new_session))
}

pub fn is_valid_expired_session_test() {
  // Create an already-expired session
  let expired =
    session.from_db(
      id: "ses_test",
      user_id: "usr_123",
      tenant_id: "ten_456",
      created_at: 1000,
      expires_at: 1001,
      // In the past
      last_active_at: 1000,
    )

  should.be_false(session.is_valid(expired))
}

// Touch tests

pub fn touch_session_test() {
  let new_session = session.create(user_id: "usr_123", tenant_id: "ten_456")
  let original_last_active = new_session.last_active_at

  let touched = session.touch(new_session)

  should.be_true(touched.last_active_at >= original_last_active)
  // Other fields should be unchanged
  should.equal(touched.id, new_session.id)
  should.equal(touched.user_id, new_session.user_id)
  should.equal(touched.tenant_id, new_session.tenant_id)
}

// Extend tests

pub fn extend_session_test() {
  let new_session = session.create(user_id: "usr_123", tenant_id: "ten_456")
  let original_expires = new_session.expires_at

  let extended = session.extend(new_session, 7200)
  // Add 2 hours

  should.be_true(extended.expires_at > original_expires)
}

// Default config test

pub fn default_config_test() {
  let config = session.default_config()

  // Default should be 7 days
  should.equal(config.expires_in_seconds, 604_800)
}

// Remaining time test

pub fn remaining_seconds_test() {
  let config = session.SessionConfig(expires_in_seconds: 3600)
  let new_session =
    session.create_with_config(
      user_id: "usr_123",
      tenant_id: "ten_456",
      config: config,
    )

  let remaining = session.remaining_seconds(new_session)

  // Should be close to 3600 (maybe a second or two less)
  should.be_true(remaining > 3590)
  should.be_true(remaining <= 3600)
}

pub fn remaining_seconds_expired_test() {
  let expired =
    session.from_db(
      id: "ses_test",
      user_id: "usr_123",
      tenant_id: "ten_456",
      created_at: 1000,
      expires_at: 1001,
      last_active_at: 1000,
    )

  let remaining = session.remaining_seconds(expired)

  // Should be 0 for expired sessions
  should.equal(remaining, 0)
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
