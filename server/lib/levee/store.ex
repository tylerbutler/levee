defmodule Levee.Store do
  @moduledoc """
  Ecto repository for PostgreSQL storage backend.

  This is only used when the storage backend is configured to use PostgreSQL.
  By default, the application uses ETS for in-memory storage.
  """

  use Ecto.Repo,
    otp_app: :levee,
    adapter: Ecto.Adapters.Postgres,
    priv: "priv/store"
end
