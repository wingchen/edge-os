defmodule EdgeOsCloudWeb.PageController do
  use EdgeOsCloudWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end

  def login(conn, _params) do
    conn
    |> put_root_layout({EdgeOsCloudWeb.LayoutView, "empty.html"})
    |> render("login.html")
  end

  def logout(conn, _params) do
    render(conn, "devices.html")
  end
end
