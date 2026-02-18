defmodule LeveeWeb.UserSocket do
  use Phoenix.Socket

  # Document channel - clients join with "document:{tenant_id}:{document_id}"
  channel "document:*", LeveeWeb.DocumentChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    # Connection is established without authentication
    # Authentication happens in the channel join via connect_document
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
