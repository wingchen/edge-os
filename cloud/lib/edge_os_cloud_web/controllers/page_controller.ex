defmodule EdgeOsCloudWeb.PageController do
  use EdgeOsCloudWeb, :controller

  def index(conn, _params) do
    render(conn, "index.html")
  end

  def login(conn, _params) do
    case get_session(conn, :current_user) do
      nil -> 
        conn
        |> put_root_layout({EdgeOsCloudWeb.LayoutView, "empty.html"})
        |> render("login.html")

      _user ->
        conn
        |> redirect(to: "/")
    end
  end

  def logout(conn, _params) do
    conn
    |> put_flash(:info, "You have been logged out!")
    |> clear_session()
    |> redirect(to: "/login")
  end
end
