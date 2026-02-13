defmodule Levee.Repo do
  use Ecto.Repo,
    otp_app: :levee,
    adapter: Ecto.Adapters.Postgres
end
