defmodule EdgeOsCloudWeb.EdgeLive.Index do
  use EdgeOsCloudWeb, :live_view
  require Logger

  alias EdgeOsCloud.Device
  alias EdgeOsCloud.Device.Edge

  @impl true
  def mount(_params, session, socket) do
    user = Map.get(session, "current_user")
    updated_socket = 
      socket
      |> assign(:edges, list_edges(user.id))
      |> assign(:current_user, user)
    {:ok, updated_socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Rename Edge")
    |> assign(:edge, Device.get_edge!(id))
  end

  defp apply_action(socket, :new, _params) do
    Logger.info("new edge!!!")

    socket
    |> assign(:page_title, "New Edge")
    |> assign(:edge, %Edge{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Edges")
    |> assign(:edge, nil)
  end

  def get_topic(edge_id) do
    "et_edge_id_#{edge_id}_to_edge"
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    Logger.debug("deleting edge #{inspect id}")
    edge = Device.get_edge!(id)
    {:ok, _} = Device.delete_edge(edge)

    %{current_user: user} = socket.assigns
    {:noreply, assign(socket, :edges, list_edges(user.id))}
  end

  @impl true
  def handle_event("ssh", %{"id" => id}, socket) do
    Logger.debug("ssh to edge #{inspect id}")
    edge = Device.get_edge!(id)
    %{current_user: user} = socket.assigns

    websocket_pid_atom = String.to_atom(get_topic(edge.id))

    case Process.whereis(websocket_pid_atom) do
      nil ->
        Logger.error("cannot find the pid for websocket process for edge #{inspect websocket_pid_atom}")

      websocket_pid ->
        {:ok, session} = Device.create_edge_session(%{
          edge_id: edge.id,
          user_id: user.id,
          host: "127.0.0.1",
          port: 123123,
        })

        cmd = "SSH #{Device.get_session_id_hash(edge, session.id)}"
        Logger.info("commading to edge #{edge.id} with command #{cmd}")
        send(websocket_pid, cmd)
    end

    {:noreply, assign(socket, :edges, list_edges(user.id))}
  end

  defp list_edges(user_id) do
    Device.list_active_account_edges(user_id)
  end
end
