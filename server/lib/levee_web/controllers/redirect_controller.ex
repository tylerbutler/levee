defmodule LeveeWeb.RedirectController do
  use LeveeWeb, :controller

  def admin(conn, _params) do
    redirect(conn, to: "/admin")
  end
end
