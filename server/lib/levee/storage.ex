defmodule Levee.Storage do
  @moduledoc """
  Minimal storage dispatch — only the functions still called by session.ex.

  Will be removed when session.ex is ported to Gleam.
  """

  @compile {:no_warn_undefined, [:levee_storage@ets]}

  def get_latest_summary(tenant_id, document_id) do
    # Call Gleam storage directly
    case :levee_storage@ets.get_latest_summary(tenant_id, document_id) do
      {:ok, summary} -> {:ok, summary}
      {:error, _} -> {:error, :not_found}
    end
  end

  def store_summary(tenant_id, document_id, summary) do
    :levee_storage@ets.store_summary(tenant_id, document_id, summary)
  end

  # Legacy: create_blob is called from document_channel for summary tree processing
  def create_blob(tenant_id, content) do
    :levee_storage@ets.create_blob(tenant_id, content)
  end
end
