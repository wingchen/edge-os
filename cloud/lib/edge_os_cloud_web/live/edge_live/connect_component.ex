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
          # we need to use an async task because UserTcpSocket init is blocking until an user connects in
          {:ok, pid} = Task.Supervisor.start_link()
          _task =
            Task.Supervisor.async(pid, fn ->
              EdgeOsCloud.Sockets.UserTcpSocket.start_link(session_port: ssh_port, session_id: session.id, user_ip: user_ip)
            end)

          Process.send_after(self(), {:check_tcp_readiness, session.id, 0}, 3000)
          socket = push_event(socket, "step2", %{note: "sending message to #{edge.name}"})
          {:noreply, socket}
        end
    end
  end

  @impl true
  def handle_event("connect", %{"id" => id, "port-number" => port_number}, socket) do
    Logger.info("connect to edge #{inspect id} to port #{port_number}")

    case Integer.parse(port_number) do
      :error ->
        Logger.error("wrong port to connect to: #{port_number}, ignoring the request")
        {:noreply, socket}

      {_port_number_int, _} ->
        edge = Device.get_edge!(id)
        %{current_user: user, user_ip: user_ip} = socket.assigns

        websocket_pid_atom = String.to_atom(get_topic(edge.id))

        case Process.whereis(websocket_pid_atom) do
          nil ->
            Logger.error("cannot find the pid for websocket process for edge #{inspect websocket_pid_atom}")
            {:noreply, socket |> put_flash(:error, "Edge is not connected to the system as we know.")}

          websocket_pid ->
            tcp_port = EdgeOsCloud.Sockets.TCPPortSelector.get_port()

            if is_nil(tcp_port) do
              Logger.error("no available port found for session on edge #{edge.id}")
              {:noreply, socket |> put_flash(:error, "EdgeOS server has resource constraint. Please contact the maintainer.")}
            else
              # tell the edge to connect in for bridging
              {:ok, session} = Device.create_edge_session(%{
                edge_id: edge.id,
                user_id: user.id,
                host: "127.0.0.1",
                port: tcp_port,
              })

              cmd = "CONNECT #{Device.get_session_id_hash(edge, session.id)} #{port_number}"
              Logger.info("commading to edge #{edge.id} with command #{cmd}")
              send(websocket_pid, cmd)

              # start a cloud tcp server to handle bridging
              # we need to use an async task because EdgeTcpSocket init is blocking until an user connects in
              {:ok, pid} = Task.Supervisor.start_link()
              _task =
                Task.Supervisor.async(pid, fn ->
                  EdgeOsCloud.Sockets.UserTcpSocket.start_link(session_port: tcp_port, session_id: session.id, user_ip: user_ip)
                end)

              Process.send_after(self(), {:check_tcp_readiness, session.id, 0}, 3000)
              socket = push_event(socket, "step2", %{note: "sending message to #{edge.name}"})
              {:noreply, socket}
            end
        end
    end
  end

  def get_topic(edge_id) do
    "et_edge_id_#{edge_id}_to_edge"
  end
end
