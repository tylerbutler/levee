defmodule Levee.Store.Migrations.CreateAuthTables do
  use Ecto.Migration

  def change do
    # Users table
    create table(:users, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:email, :string, null: false)
      add(:password_hash, :string, null: false)
      add(:display_name, :string)

      timestamps(type: :bigint)
    end

    create(unique_index(:users, [:email]))

    # Tenants table
    create table(:tenants, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:name, :string, null: false)
      add(:slug, :string, null: false)

      timestamps(type: :bigint)
    end

    create(unique_index(:tenants, [:slug]))

    # Tenant memberships (user <-> tenant join table)
    create table(:tenant_memberships, primary_key: false) do
      add(:user_id, references(:users, type: :string, on_delete: :delete_all), primary_key: true)

      add(:tenant_id, references(:tenants, type: :string, on_delete: :delete_all),
        primary_key: true
      )

      add(:role, :string, null: false, default: "member")
      add(:joined_at, :bigint, null: false)
    end

    create(index(:tenant_memberships, [:user_id]))
    create(index(:tenant_memberships, [:tenant_id]))

    # Sessions table
    create table(:sessions, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:user_id, references(:users, type: :string, on_delete: :delete_all), null: false)
      add(:tenant_id, references(:tenants, type: :string, on_delete: :delete_all))

      add(:created_at, :bigint, null: false)
      add(:expires_at, :bigint, null: false)
      add(:last_active_at, :bigint, null: false)
    end

    create(index(:sessions, [:user_id]))
    create(index(:sessions, [:tenant_id]))
    create(index(:sessions, [:expires_at]))
    create(index(:sessions, [:user_id, :tenant_id, :expires_at]))

    # Invites table
    create table(:invites, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:token, :string, null: false)
      add(:email, :string, null: false)
      add(:tenant_id, references(:tenants, type: :string, on_delete: :delete_all), null: false)
      add(:invited_by_id, references(:users, type: :string, on_delete: :nilify_all))
      add(:role, :string, null: false, default: "member")
      add(:status, :string, null: false, default: "pending")

      add(:created_at, :bigint, null: false)
      add(:expires_at, :bigint, null: false)
    end

    create(unique_index(:invites, [:token]))
    create(index(:invites, [:tenant_id]))
    create(index(:invites, [:email]))
  end
end
