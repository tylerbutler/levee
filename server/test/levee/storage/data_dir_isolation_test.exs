defmodule Levee.Storage.DataDirIsolationTest do
  @moduledoc """
  Guards against a cross-run flake.

  `Levee.Storage.GleamETS` persists to DETS on disk and reloads it on boot,
  but test document IDs come from `System.unique_integer/1`, which is only
  unique *within* one VM run. When the suite shared the dev store, documents
  accumulated across runs forever and a fresh ID could collide with residue
  from an earlier run — surfacing as a sporadic `{:error, :already_exists}`
  in whichever test happened to lose the race.

  The store must therefore be a fresh directory per run. Wiping a fixed
  directory from `test_helper.exs` is *not* equivalent: `mix test` starts the
  application before the helper runs, so the wipe would unlink the DETS files
  under already-open tables.
  """
  use ExUnit.Case, async: true

  @dev_default Path.join(File.cwd!(), "priv/storage/dets")

  setup do
    {:ok, dir: Application.get_env(:levee, :storage_data_dir)}
  end

  test "the suite does not write to the dev store", %{dir: dir} do
    refute is_nil(dir),
           "config/test.exs must set :storage_data_dir so tests never write to #{@dev_default}"

    refute Path.expand(dir) == Path.expand(@dev_default),
           "test storage must not share the dev DETS store at #{@dev_default}"
  end

  test "each run gets its own storage directory", %{dir: dir} do
    run_root = Path.join(System.tmp_dir!(), "levee-test-storage")

    assert String.starts_with?(Path.expand(dir), Path.expand(run_root)),
           "expected a per-run directory under #{run_root}, got #{dir}"

    refute Path.basename(dir) == Path.basename(run_root),
           "storage directory must carry a per-run suffix, otherwise two runs share it"
  end

  test "the run's directory is removed at exit" do
    assert :persistent_term.get(:levee_test_storage_cleanup_registered, false),
           "test_helper.exs must register a System.at_exit/1 cleanup for the run's " <>
             "storage directory, or tmp fills up with one directory per run"
  end
end
