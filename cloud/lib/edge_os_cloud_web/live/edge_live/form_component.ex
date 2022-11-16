defmodule EdgeOsCloudWeb.EdgeLive.FormComponent do
  use EdgeOsCloudWeb, :live_component

  alias EdgeOsCloud.Device

  @impl true
  def update(%{edge: edge} = assigns, socket) do
    changeset = Device.change_edge(edge)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)}
  end

  @impl true
  def handle_event("validate", %{"edge" => edge_params}, socket) do
    changeset =
      socket.assigns.edge
      |> Device.change_edge(edge_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"edge" => edge_params}, socket) do
    save_edge(socket, socket.assigns.action, edge_params)
  end

  defp save_edge(socket, :edit, edge_params) do
    case Device.update_edge(socket.assigns.edge, edge_params) do
      {:ok, _edge} ->
        {:noreply,
         socket
         |> put_flash(:info, "Edge updated successfully")
         |> push_redirect(to: socket.assigns.return_to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_edge(socket, :new, edge_params) do
    case Device.create_edge(edge_params) do
      {:ok, _edge} ->
        {:noreply,
         socket
         |> put_flash(:info, "Edge created successfully")
         |> push_redirect(to: socket.assigns.return_to)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end
end
