defmodule EdgeOsCloudWeb.EdgeLive.Index do
  use EdgeOsCloudWeb, :live_view
  require Logger

  alias EdgeOsCloud.Device
  alias EdgeOsCloud.Device.Edge

  @impl true
  def mount(_params, session, socket) do
    case Map.get(session, "current_user") do
      nil ->
        {:ok, redirect(socket, to: "/login")}

      user ->
        peer_data = get_connect_info(socket, :peer_data)

        user_ip = case peer_data do
          nil -> {127, 0, 0, 1}
          peer_data -> peer_data.address
        end

        updated_socket = 
          socket
          |> assign(:edges, list_edges(user.id))
          |> assign(:current_user, user)
          |> assign(:user_ip, user_ip)

        {:ok, updated_socket}
    end
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

  defp apply_action(socket, :connect, %{"id" => id}) do
    socket
    |> assign(:page_title, "Connect to an Edge Port")
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
    |> assign(:page_title, "Edge List")
    |> assign(:edge, nil)
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
  def handle_event("info", %{"id" => id}, socket) do
    {:noreply, redirect(socket, to: "/dash/edge/#{id}")}
  end

  @impl true
  def handle_info({_reference, {:ok, ssh_pid}}, socket) do
    Logger.debug("ssh session #{inspect ssh_pid} terminated")
    # TODL: Device.append_edge_session_action(session.id, EdgeSessionStage.user_disconnected)    
    {:noreply, socket}
  end

  def handle_info({:DOWN, _reference, :process, ssh_pid, :normal}, socket) do
    Logger.debug("ssh session #{inspect ssh_pid} terminated")
    # TODL: Device.append_edge_session_action(session.id, EdgeSessionStage.user_disconnected)    
    {:noreply, socket}
  end

  def handle_info({:check_tcp_readiness, session_id, counter}, socket) do
    if counter >= 3 do
      Logger.warn("timeout trying to establish tcp session for #{session_id}. updating the UI")
      note = "We are not seeing the rigth processes from edge and server launched. Are you sure that there is an edge process running on the port? Please contact the system admin if this keeps happening."
      socket = push_event(socket, "ssh_error", %{title: "Timeout! TCP tunnel NOT established", note: note})
      {:noreply, socket}
    else
      if is_session_ready(session_id) do
        Logger.debug("ssh session for #{session_id} is ready. updating the UI")
        cloud_url = System.get_env("PHX_HOST", "127.0.0.1")
        session = Device.get_edge_session!(session_id)
        
        random_session_hash = EdgeOsCloud.HashIdHelper.encode(session_id, UUID.uuid4()) |> String.slice(0..5) |> String.downcase()
        command = "ssh [your_account_name]@#{random_session_hash}.#{cloud_url} -p #{session.port}"

        socket = push_event(socket, "step3", 
          %{
            title: "TCP tunnel established", 
            note: "For examaple, you can use the following ssh command to connect in if you chose to connect to edge port 22. The connection process will end as soon as you exit the ssh session.",
            command: command
          }
        )

        Process.send_after(self(), {:ssh_disconnected, session_id}, 3000)
        {:noreply, socket}
      else
        # schedule for the next check
        Logger.debug("ssh session for #{session_id} is not ready. check in again in secs")
        socket = push_event(socket, "step2", %{note: "still working on it..."})
        Process.send_after(self(), {:check_tcp_readiness, session_id, counter + 1}, 3000)
        {:noreply, socket}
      end
    end
  end

  def handle_info({:ssh_disconnected, session_id}, socket) do
    if is_session_ready(session_id) do
      # check again in 3 secs until the session is finished
      Process.send_after(self(), {:ssh_disconnected, session_id}, 3000)
      {:noreply, socket}
    else
      socket = push_event(socket, "step3", 
        %{
          title: "SSH session finished", 
          finishnote: "Your ssh session is concluded. Please start a new one if you wish to do more operations.",
          disconnected: "true"
        }
      )

      {:noreply, socket}
    end
  end

  defp is_session_ready(session_id) do
    user_process_ready = case Process.whereis(EdgeOsCloud.Sockets.EdgeTcpSocket.get_pid(session_id)) do
      nil -> false
      _user_pid -> true
    end

    edge_process_ready = case Process.whereis(EdgeOsCloud.Sockets.EdgeTcpSocket.get_pid(session_id)) do
      nil -> false
      _user_pid -> true
    end

    user_process_ready and edge_process_ready
  end

  defp list_edges(user_id) do
    Device.list_active_account_edges(user_id)
  end
end
