defmodule EdgeOsCloudWeb.PageController do
  use EdgeOsCloudWeb, :controller
  require Logger

  alias EdgeOsCloud.Device
  alias EdgeOsCloud.Accounts

  def index(conn, _params) do
    case get_session(conn, :current_user) do
      nil  -> redirect(conn, to: "/login")
      _user -> redirect(conn, to: "/edges")
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

  def me(conn, _params) do
    case get_session(conn, :current_user) do
      nil ->
        conn
        |> put_flash(:info, "You have been logged out!")
        |> clear_session()
        |> redirect(to: "/login")

      user ->
        user_token = case Accounts.get_user_token(user) do
          {:ok, nil} ->
            {:ok, token} = Accounts.create_user_token(user)
            token
          {:ok, token} ->
            token
        end

        teams_with_hash =
          Accounts.list_teams_for_user(user.id)
          |> Enum.map(fn team ->
            {team, Accounts.get_team_id_hash(team.id)}
          end)

        cloud_url = "wss://#{System.get_env("PHX_HOST", "edgeos.sailoi.com")}"

        conn
        |> assign(:current_user, user)
        |> assign(:token, user_token)
        |> assign(:teams_with_hash, teams_with_hash)
        |> assign(:cloud_url, cloud_url)
        |> render("me.html")
    end
  end
end
