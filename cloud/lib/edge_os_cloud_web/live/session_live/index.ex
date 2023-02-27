defmodule EdgeOsCloudWeb.SessionLive.Index do
  use EdgeOsCloudWeb, :live_view

  alias EdgeOsCloud.Device

  @impl true
  def mount(_params, session, socket) do
    case Map.get(session, "current_user") do
      nil ->
        {:ok, redirect(socket, to: "/login")}

      user ->
        user_edges = Device.list_active_account_edges(user.id)
        user_edge_ids = user_edges |> Enum.map(fn e -> e.id end)
        user_edge_map = Enum.into(user_edges, %{}, fn x -> {x.id, x} end)

        updated_socket = 
          socket
          |> assign(:sessions, Device.list_sessions(user_edge_ids))
          |> assign(:edge_map, user_edge_map)

        {:ok, updated_socket}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Sessions")
    |> assign(:session, nil)
  end

  # @impl true
  # def handle_event("delete", %{"id" => id}, socket) do
  #   session = Device.get_session!(id)
  #   {:ok, _} = Device.delete_session(session)

  #   {:noreply, assign(socket, :sessions, list_sessions())}
  # end
end
