defmodule Levee.Storage.GleamMesaTest do
  use ExUnit.Case, async: false

  @backend Levee.Storage.GleamMesa

  setup_all do
    start_supervised!(@backend)
    :ok
  end

  test "scaffolded backend is wired and returns not_implemented" do
    assert {:error, :not_implemented} =
             @backend.create_document("tenant", "doc", %{sequence_number: 0})

    assert {:error, :not_implemented} = @backend.list_documents("tenant")
  end
end
