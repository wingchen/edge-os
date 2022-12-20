defmodule EdgeOsCloudWeb.EdgeLive.SSHComponent do
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
    Logger.debug("ssh to edge #{inspect id}")
    edge = Device.get_edge!(id)
    %{current_user: user, user_ip: user_ip} = socket.assigns

    websocket_pid_atom = String.to_atom(get_topic(edge.id))

    case Process.whereis(websocket_pid_atom) do
      nil ->
        Logger.error("cannot find the pid for websocket process for edge #{inspect websocket_pid_atom}")
        {:noreply, socket |> put_flash(:error, "Edge is not connected to the system as we know.")}

      websocket_pid ->
        ssh_port = EdgeOsCloud.Sockets.TCPPortSelector.get_port()

        if is_nil(ssh_port) do
          Logger.error("no available port found for ssh session on edge #{edge.id}")
          {:noreply, socket |> put_flash(:error, "EdgeOS server has resource constraint. Please contact the maintainer.")}
        else
          # tell the edge to connect in for ssh bridging
          {:ok, session} = Device.create_edge_session(%{
            edge_id: edge.id,
            user_id: user.id,
            host: "127.0.0.1",
            port: ssh_port,
          })

          cmd = "SSH #{Device.get_session_id_hash(edge, session.id)}"
          Logger.info("commading to edge #{edge.id} with command #{cmd}")
          send(websocket_pid, cmd)

          # start a cloud ssh server to handle bridging
          # we need to use an async task because UserSSHSocket init is blocking until an user connects in
          {:ok, pid} = Task.Supervisor.start_link()
          _task =
            Task.Supervisor.async(pid, fn ->
              EdgeOsCloud.Sockets.UserSSHSocket.start_link(session_port: ssh_port, session_id: session.id, user_ip: user_ip)
            end)

          Process.send_after(self(), {:check_ssh_readiness, session.id, 0}, 3000)
          socket = push_event(socket, "step2", %{note: "sending message to #{edge.name}"})
          {:noreply, socket}
        end
    end
  end

  def get_topic(edge_id) do
    "et_edge_id_#{edge_id}_to_edge"
  end
end
