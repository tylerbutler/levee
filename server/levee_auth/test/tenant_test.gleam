import gleeunit/should
import tenant

// Tenant creation tests

pub fn create_tenant_test() {
  let result =
    tenant.create(name: "Acme Corp", slug: "acme-corp", owner_id: "usr_123")

  should.be_ok(result)

  let assert Ok(#(new_tenant, membership)) = result
  should.equal(new_tenant.name, "Acme Corp")
  should.equal(new_tenant.slug, "acme-corp")
  should.be_true(has_prefix(new_tenant.id, "ten_"))
  should.be_true(new_tenant.created_at > 0)
  should.equal(new_tenant.created_at, new_tenant.updated_at)

  // Owner membership should be created
  should.equal(membership.user_id, "usr_123")
  should.equal(membership.tenant_id, new_tenant.id)
  should.equal(membership.role, tenant.Owner)
}

pub fn create_tenant_invalid_slug_test() {
  // Slug with spaces should fail
  let result =
    tenant.create(name: "Test", slug: "has spaces", owner_id: "usr_1")
  should.be_error(result)
  should.equal(result, Error(tenant.InvalidSlug))
}

pub fn create_tenant_empty_name_test() {
  let result = tenant.create(name: "", slug: "valid-slug", owner_id: "usr_1")
  should.be_error(result)
  should.equal(result, Error(tenant.InvalidName))
}

pub fn create_tenant_slug_too_short_test() {
  let result = tenant.create(name: "Test", slug: "ab", owner_id: "usr_1")
  should.be_error(result)
  should.equal(result, Error(tenant.InvalidSlug))
}

// Slug validation tests

pub fn validate_slug_valid_test() {
  should.be_true(tenant.is_valid_slug("my-company"))
  should.be_true(tenant.is_valid_slug("company123"))
  should.be_true(tenant.is_valid_slug("my_company"))
  should.be_true(tenant.is_valid_slug("abc"))
}

pub fn validate_slug_invalid_test() {
  should.be_false(tenant.is_valid_slug("has spaces"))
  should.be_false(tenant.is_valid_slug("UPPERCASE"))
  should.be_false(tenant.is_valid_slug("special@chars"))
  should.be_false(tenant.is_valid_slug("ab"))
  // 2 chars too short
  should.be_false(tenant.is_valid_slug("-starts-with-dash"))
  should.be_false(tenant.is_valid_slug("ends-with-dash-"))
}

// Update tests

pub fn update_name_test() {
  let assert Ok(#(t, _)) =
    tenant.create(name: "Old Name", slug: "test-slug", owner_id: "usr_1")

  let updated = tenant.update_name(t, "New Name")

  should.equal(updated.name, "New Name")
  should.be_true(updated.updated_at >= t.updated_at)
}

// Role tests

pub fn role_to_string_test() {
  should.equal(tenant.role_to_string(tenant.Owner), "owner")
  should.equal(tenant.role_to_string(tenant.Admin), "admin")
  should.equal(tenant.role_to_string(tenant.Member), "member")
  should.equal(tenant.role_to_string(tenant.Viewer), "viewer")
}

pub fn role_from_string_test() {
  should.equal(tenant.role_from_string("owner"), Ok(tenant.Owner))
  should.equal(tenant.role_from_string("admin"), Ok(tenant.Admin))
  should.equal(tenant.role_from_string("member"), Ok(tenant.Member))
  should.equal(tenant.role_from_string("viewer"), Ok(tenant.Viewer))
  should.equal(tenant.role_from_string("invalid"), Error(Nil))
}

// Permission tests

pub fn can_manage_members_test() {
  should.be_true(tenant.can_manage_members(tenant.Owner))
  should.be_true(tenant.can_manage_members(tenant.Admin))
  should.be_false(tenant.can_manage_members(tenant.Member))
  should.be_false(tenant.can_manage_members(tenant.Viewer))
}

pub fn can_update_tenant_test() {
  should.be_true(tenant.can_update_tenant(tenant.Owner))
  should.be_true(tenant.can_update_tenant(tenant.Admin))
  should.be_false(tenant.can_update_tenant(tenant.Member))
  should.be_false(tenant.can_update_tenant(tenant.Viewer))
}

pub fn can_delete_tenant_test() {
  should.be_true(tenant.can_delete_tenant(tenant.Owner))
  should.be_false(tenant.can_delete_tenant(tenant.Admin))
  should.be_false(tenant.can_delete_tenant(tenant.Member))
  should.be_false(tenant.can_delete_tenant(tenant.Viewer))
}

// Membership tests

pub fn create_membership_test() {
  let m = tenant.create_membership("usr_abc", "ten_xyz", tenant.Member)

  should.equal(m.user_id, "usr_abc")
  should.equal(m.tenant_id, "ten_xyz")
  should.equal(m.role, tenant.Member)
  should.be_true(m.joined_at > 0)
}

pub fn update_membership_role_test() {
  let m = tenant.create_membership("usr_abc", "ten_xyz", tenant.Member)
  let updated = tenant.update_role(m, tenant.Admin)

  should.equal(updated.role, tenant.Admin)
  should.equal(updated.user_id, m.user_id)
  should.equal(updated.tenant_id, m.tenant_id)
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
