import gleam/option
import gleeunit/should
import user

// User creation tests

pub fn create_user_test() {
  let result =
    user.create(
      email: "test@example.com",
      password: "secure_password_123",
      display_name: "Test User",
    )

  should.be_ok(result)

  let assert Ok(new_user) = result
  should.equal(new_user.email, "test@example.com")
  should.equal(new_user.display_name, "Test User")
  // ID should be generated with usr_ prefix
  should.be_true(has_prefix(new_user.id, "usr_"))
  // Password hash should be set (not the raw password)
  should.be_true(has_prefix(new_user.password_hash, "$pbkdf2-sha256"))
  // Timestamps should be set
  should.be_true(new_user.created_at > 0)
  should.equal(new_user.created_at, new_user.updated_at)
}

pub fn create_user_empty_display_name_test() {
  let result =
    user.create(
      email: "test@example.com",
      password: "password123",
      display_name: "",
    )

  should.be_ok(result)

  let assert Ok(new_user) = result
  // Empty display name should derive from email
  should.equal(new_user.display_name, "test")
}

pub fn create_user_invalid_email_test() {
  let result =
    user.create(
      email: "not-an-email",
      password: "password123",
      display_name: "Test",
    )

  should.be_error(result)
  should.equal(result, Error(user.InvalidEmail))
}

pub fn create_user_password_too_short_test() {
  let result =
    user.create(
      email: "test@example.com",
      password: "short",
      display_name: "Test",
    )

  should.be_error(result)
  should.equal(result, Error(user.PasswordTooShort))
}

// Password verification tests

pub fn verify_password_correct_test() {
  let assert Ok(new_user) =
    user.create(
      email: "test@example.com",
      password: "correct_password",
      display_name: "Test",
    )

  should.be_true(user.verify_password(new_user, "correct_password"))
}

pub fn verify_password_wrong_test() {
  let assert Ok(new_user) =
    user.create(
      email: "test@example.com",
      password: "correct_password",
      display_name: "Test",
    )

  should.be_false(user.verify_password(new_user, "wrong_password"))
}

// Update tests

pub fn update_display_name_test() {
  let assert Ok(new_user) =
    user.create(
      email: "test@example.com",
      password: "password123",
      display_name: "Old",
    )

  let updated = user.update_display_name(new_user, "New Name")

  should.equal(updated.display_name, "New Name")
  should.be_true(updated.updated_at >= new_user.updated_at)
}

pub fn change_password_test() {
  let assert Ok(new_user) =
    user.create(
      email: "test@example.com",
      password: "old_password",
      display_name: "Test",
    )

  let result =
    user.change_password(new_user, "old_password", "new_password_123")

  should.be_ok(result)

  let assert Ok(updated) = result
  should.be_false(user.verify_password(updated, "old_password"))
  should.be_true(user.verify_password(updated, "new_password_123"))
}

pub fn change_password_wrong_current_test() {
  let assert Ok(new_user) =
    user.create(
      email: "test@example.com",
      password: "correct_password",
      display_name: "Test",
    )

  let result =
    user.change_password(new_user, "wrong_password", "new_password_123")

  should.be_error(result)
  should.equal(result, Error(user.InvalidCurrentPassword))
}

pub fn change_password_new_too_short_test() {
  let assert Ok(new_user) =
    user.create(
      email: "test@example.com",
      password: "correct_password",
      display_name: "Test",
    )

  let result = user.change_password(new_user, "correct_password", "short")

  should.be_error(result)
  should.equal(result, Error(user.PasswordTooShort))
}

// Serialization tests

pub fn to_public_test() {
  let assert Ok(new_user) =
    user.create(
      email: "test@example.com",
      password: "password123",
      display_name: "Test User",
    )

  let public = user.to_public(new_user)

  should.equal(public.id, new_user.id)
  should.equal(public.email, new_user.email)
  should.equal(public.display_name, new_user.display_name)
  should.equal(public.created_at, new_user.created_at)
}

// OAuth user creation tests

pub fn create_oauth_user_test() {
  let oauth_user =
    user.create_oauth(
      email: "github@example.com",
      display_name: "GitHub User",
      github_id: "12345",
    )

  should.equal(oauth_user.email, "github@example.com")
  should.equal(oauth_user.display_name, "GitHub User")
  should.equal(oauth_user.github_id, option.Some("12345"))
  should.equal(oauth_user.password_hash, "")
  should.be_true(has_prefix(oauth_user.id, "usr_"))
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
