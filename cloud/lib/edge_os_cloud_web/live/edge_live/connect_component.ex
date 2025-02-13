defmodule EdgeOsCloudWeb.EdgeLive.ConnectComponent do
  use EdgeOsCloudWeb, :live_component
  require Logger

  alias EdgeOsCloud.Device

  @impl true
  def update(%{edge: edge, current_user: current_user, user_ip: user_ip} = assigns, socket) do
    changeset = Device.change_edge(edge)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)
     |> assign(:current_user, current_user)
     |> assign(:user_ip, user_ip)
    }
  end

  @impl true
  def handle_event("ssh", %{"id" => id}, socket) do
    edge = Device.get_edge!(id)
    %{current_user: user, user_ip: user_ip} = socket.assigns

    case EdgeOsCloud.Sockets.EdgeSSHUtils.create_ssh_connection(user, edge, user_ip) do
      {:error, message} ->
        Logger.error("connect to edge, with error: #{message}")
        {:noreply, socket |> put_flash(:error, message)}

      {:ok, session, message} ->
        Logger.info("commanding to edge: #{message}")
        Process.send_after(self(), {:check_tcp_readiness, session.id, 0}, 3000)
        socket = push_event(socket, "step2", %{note: "sending message to #{edge.name}"})
        {:noreply, socket}
    end
  end
end
