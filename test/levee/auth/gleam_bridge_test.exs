defmodule Levee.Auth.GleamBridgeTest do
  use ExUnit.Case, async: true

  alias Levee.Auth.GleamBridge

  describe "password hashing" do
    test "hash_password returns a pbkdf2 hash" do
      {:ok, hash} = GleamBridge.hash_password("secure_password_123")

      assert String.starts_with?(hash, "$pbkdf2-sha256")
    end

    test "verify_password returns true for correct password" do
      {:ok, hash} = GleamBridge.hash_password("correct_password")

      assert GleamBridge.verify_password("correct_password", hash) == true
    end

    test "verify_password returns false for wrong password" do
      {:ok, hash} = GleamBridge.hash_password("correct_password")

      assert GleamBridge.verify_password("wrong_password", hash) == false
    end
  end

  describe "user management" do
    test "create_user returns a user with generated ID" do
      {:ok, user} = GleamBridge.create_user("test@example.com", "password123", "Test User")

      assert String.starts_with?(user.id, "usr_")
      assert user.email == "test@example.com"
      assert user.display_name == "Test User"
      assert user.created_at > 0
    end

    test "create_user validates email" do
      {:error, :invalid_email} = GleamBridge.create_user("not-an-email", "password123", "Test")
    end

    test "create_user validates password length" do
      {:error, :password_too_short} =
        GleamBridge.create_user("test@example.com", "short", "Test")
    end

    test "verify_user_password checks against user's hash" do
      {:ok, user} = GleamBridge.create_user("test@example.com", "password123", "Test")

      assert GleamBridge.verify_user_password(user, "password123") == true
      assert GleamBridge.verify_user_password(user, "wrong") == false
    end
  end

  describe "tenant management" do
    test "create_tenant returns tenant and owner membership" do
      {:ok, {tenant, membership}} = GleamBridge.create_tenant("Acme Corp", "acme-corp", "usr_123")

      assert String.starts_with?(tenant.id, "ten_")
      assert tenant.name == "Acme Corp"
      assert tenant.slug == "acme-corp"

      assert membership.user_id == "usr_123"
      assert membership.tenant_id == tenant.id
      assert membership.role == :owner
    end

    test "create_tenant validates slug format" do
      {:error, :invalid_slug} = GleamBridge.create_tenant("Test", "has spaces", "usr_123")
    end

    test "create_tenant validates name" do
      {:error, :invalid_name} = GleamBridge.create_tenant("", "valid-slug", "usr_123")
    end
  end

  describe "session management" do
    test "create_session returns a valid session" do
      session = GleamBridge.create_session("usr_123", "ten_456")

      assert String.starts_with?(session.id, "ses_")
      assert session.user_id == "usr_123"
      assert session.tenant_id == "ten_456"
      assert session.expires_at > session.created_at
    end

    test "is_session_valid? returns true for fresh session" do
      session = GleamBridge.create_session("usr_123", "ten_456")

      assert GleamBridge.is_session_valid?(session) == true
    end

    test "touch_session updates last_active_at" do
      session = GleamBridge.create_session("usr_123", "ten_456")
      touched = GleamBridge.touch_session(session)

      assert touched.last_active_at >= session.last_active_at
    end
  end

  describe "invite management" do
    test "create_invite returns an invite with token" do
      {:ok, invite} = GleamBridge.create_invite("new@example.com", "ten_123", :member, "usr_456")

      assert String.starts_with?(invite.id, "inv_")
      assert invite.email == "new@example.com"
      assert invite.tenant_id == "ten_123"
      assert invite.role == :member
      assert invite.status == :pending
      assert String.length(invite.token) > 20
    end

    test "create_invite validates email" do
      {:error, :invalid_email} =
        GleamBridge.create_invite("not-an-email", "ten_123", :member, "usr_456")
    end

    test "is_invite_valid? returns true for pending invite" do
      {:ok, invite} = GleamBridge.create_invite("new@example.com", "ten_123", :member, "usr_456")

      assert GleamBridge.is_invite_valid?(invite) == true
    end

    test "accept_invite changes status" do
      {:ok, invite} = GleamBridge.create_invite("new@example.com", "ten_123", :member, "usr_456")
      accepted = GleamBridge.accept_invite(invite)

      assert accepted.status == :accepted
      assert GleamBridge.is_invite_valid?(accepted) == false
    end
  end

  describe "token management" do
    @secret "test-secret-key-for-testing"

    test "create_document_token returns a JWT" do
      token = GleamBridge.create_document_token("usr_1", "ten_1", "doc_1", [:doc_read], @secret)

      # JWTs have 3 parts separated by dots
      assert length(String.split(token, ".")) == 3
    end

    test "verify_token returns claims for valid token" do
      token =
        GleamBridge.create_document_token(
          "usr_123",
          "ten_456",
          "doc_789",
          [:doc_read, :doc_write],
          @secret
        )

      {:ok, claims} = GleamBridge.verify_token(token, @secret)

      assert claims.user_id == "usr_123"
      assert claims.tenant_id == "ten_456"
      assert claims.document_id == "doc_789"
      assert :doc_read in claims.scopes
      assert :doc_write in claims.scopes
    end

    test "verify_token returns error for wrong secret" do
      token = GleamBridge.create_document_token("usr_1", "ten_1", "doc_1", [:doc_read], @secret)

      {:error, :invalid_signature} = GleamBridge.verify_token(token, "wrong-secret")
    end
  end

  describe "role permissions" do
    test "can_manage_members? checks role permissions" do
      assert GleamBridge.can_manage_members?(:owner) == true
      assert GleamBridge.can_manage_members?(:admin) == true
      assert GleamBridge.can_manage_members?(:member) == false
      assert GleamBridge.can_manage_members?(:viewer) == false
    end

    test "can_delete_tenant? only allows owner" do
      assert GleamBridge.can_delete_tenant?(:owner) == true
      assert GleamBridge.can_delete_tenant?(:admin) == false
      assert GleamBridge.can_delete_tenant?(:member) == false
    end
  end
end
