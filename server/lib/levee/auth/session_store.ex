defmodule Levee.Auth.SessionStore do
  @moduledoc """
  In-memory store for users and sessions.

  This is a temporary implementation for development.
  Will be replaced with database storage when available.
  """

  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{users: %{}, sessions: %{}} end, name: __MODULE__)
  end

  # User operations

  def store_user(user) do
    Agent.update(__MODULE__, fn state ->
      put_in(state, [:users, user.id], user)
    end)
  end

  def get_user(user_id) do
    Agent.get(__MODULE__, fn state ->
      case get_in(state, [:users, user_id]) do
        nil -> :error
        user -> {:ok, user}
      end
    end)
  end

  def find_user_by_email(email) do
    Agent.get(__MODULE__, fn state ->
      state.users
      |> Map.values()
      |> Enum.find_value(:error, fn user ->
        if user.email == email, do: {:ok, user}, else: nil
      end)
    end)
  end

  def find_user_by_github_id(github_id) do
    Agent.get(__MODULE__, fn state ->
      state.users
      |> Map.values()
      |> Enum.find_value(:error, fn user ->
        if user.github_id == github_id, do: {:ok, user}, else: nil
      end)
    end)
  end

  # Session operations

  def store_session(session) do
    Agent.update(__MODULE__, fn state ->
      put_in(state, [:sessions, session.id], session)
    end)
  end

  @doc """
  Get a session by ID. Optionally validates the session belongs to the given tenant.
  """
  def get_session(session_id, tenant_id \\ nil) do
    Agent.get(__MODULE__, fn state ->
      case get_in(state, [:sessions, session_id]) do
        nil ->
          :error

        session ->
          if tenant_id == nil or session.tenant_id == tenant_id do
            {:ok, session}
          else
            :error
          end
      end
    end)
  end

  def delete_session(session_id) do
    Agent.update(__MODULE__, fn state ->
      update_in(state, [:sessions], &Map.delete(&1, session_id))
    end)
  end

  # Clear all data (useful for tests)

  def clear do
    Agent.update(__MODULE__, fn _state ->
      %{users: %{}, sessions: %{}}
    end)
  end
end
