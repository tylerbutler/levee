defmodule Levee.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Levee.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Levee.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Levee.DataCase
    end
  end

  setup tags do
    Levee.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    # Only set up sandbox if using PostgreSQL backend
    if Application.get_env(:levee, :storage_backend) == Levee.Storage.Postgres do
      pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Levee.Repo, shared: not tags[:async])
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    end
  end
end
