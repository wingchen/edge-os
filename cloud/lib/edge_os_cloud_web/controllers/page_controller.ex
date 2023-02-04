defmodule EdgeOsCloudWeb.PageController do
  use EdgeOsCloudWeb, :controller
  require Logger

  alias EdgeOsCloud.Device

  def index(conn, _params) do
    case get_session(conn, :current_user) do
      nil -> 
        conn
        |> redirect(to: "/login")

      user ->
        user_edges = Device.list_active_account_edges(user.id)
        user_online_edges = Enum.filter(user_edges, fn x -> Device.edge_online?(x.id) end)
        user_edge_map = Enum.into(user_edges, %{}, fn x -> {x.id, x} end)

        # get edge beacon counts
        edges_statuss = Device.list_recent_edge_status_from_edges(user_edges |> Enum.map(fn x -> x.id end))
        timestamps = edges_statuss |> Enum.map(fn [t, _ei, _c] -> t end) |> Enum.uniq()

        # this generates a nested map: {edge_id, edge_name} -> timestamp -> count
        edges_statuss_map = Enum.reduce(edges_statuss, %{}, fn [t, ei, c], acc ->
          edge = user_edge_map[ei]
          key = {ei, edge.name}

          if Map.has_key?(acc, key) do
            # add the edge id and count into the map
            sub_map = acc[key]
            Map.put(acc, key, Map.put(sub_map, t, c))
          else
            # create a new key in the map
            Map.put(acc, key, %{t => c})
          end
        end)

        conn
        |> assign(:current_user, user)
        |> assign(:user_edges, user_edges)
        |> assign(:timestamps, timestamps)
        |> assign(:edges_statuss_map, edges_statuss_map)
        |> assign(:user_online_edges, length(user_online_edges))
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
