defmodule LeveeWeb.SandbagController do
  use LeveeWeb, :controller

  def index(conn, _params) do
    conn
    |> put_resp_content_type("text/html")
    |> send_file(200, Application.app_dir(:levee, "priv/static/sandbag/index.html"))
  end
end
