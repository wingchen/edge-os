defmodule EdgeOsCloudWeb.PageController do
  use EdgeOsCloudWeb, :controller
  require Logger

  def index(conn, _params) do
    case get_session(conn, :current_user) do
      nil -> 
        conn
        |> redirect(to: "/login")

      user ->
        conn
        |> assign(:current_user, user)
        |> render("index.html")
    end
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
    case get_session(conn, :current_user) do
      nil -> 
        Logger.error("user is trying to logout, but she is not logged in")

      user ->
        EdgeOsCloud.Accounts.log_user_action(%{
          user: user.id,
          action: "logout",
          meta: Jason.encode!(%{ip: EdgeOsCloud.RemoteIp.get(conn)})
        })
    end

    conn
    |> put_flash(:info, "You have been logged out!")
    |> clear_session()
    |> redirect(to: "/login")
  end
end
