defmodule Levee.Storage.GleamPGTest do
  use ExUnit.Case, async: false
  @moduletag :postgres

  @backend Levee.Storage.GleamPG
  use Levee.StorageBackendCase
end
