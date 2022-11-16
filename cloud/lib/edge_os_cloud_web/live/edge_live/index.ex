defmodule EdgeOsCloudWeb.EdgeLive.Index do
  use EdgeOsCloudWeb, :live_view

  alias EdgeOsCloud.Device
  alias EdgeOsCloud.Device.Edge

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :edges, list_edges())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Edge")
    |> assign(:edge, Device.get_edge!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Edge")
    |> assign(:edge, %Edge{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Edges")
    |> assign(:edge, nil)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    edge = Device.get_edge!(id)
    {:ok, _} = Device.delete_edge(edge)

    {:noreply, assign(socket, :edges, list_edges())}
  end

  defp list_edges do
    Device.list_edges()
  end
end
