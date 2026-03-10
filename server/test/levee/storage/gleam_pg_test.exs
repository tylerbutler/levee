defmodule Levee.Storage.GleamPGTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  @backend Levee.Storage.GleamPG
  use Levee.StorageBackendCase

  setup_all do
    database_url =
      System.get_env("DATABASE_URL") ||
        "postgres://levee:levee@localhost:5432/levee_test"

    start_supervised!({Levee.Storage.GleamPG, database_url: database_url})
    :ok
  end

  setup do
    Levee.Storage.GleamPG.truncate_all()
    :ok
  end
end
