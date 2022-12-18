defmodule EdgeOsCloud.Sockets.UserSSHSocket do
  use GenServer
  require Logger

  def get_pid(session_id) do
    String.to_atom("edge_session_id_#{session_id}_to_ssh")
  end

  def start_link(ops) do
    session_port = Keyword.get(ops, :session_port)
    session_id = Keyword.get(ops, :session_id)
    user_ip = Keyword.get(ops, :user_ip)
    Logger.info("starting ssh servers at #{session_port} for session #{session_id} and user at #{inspect user_ip}")

    if is_nil(session_port) do
      raise "session_port cannot be nil"
    end

    if is_nil(session_id) do
      raise "session_id cannot be nil"
    end

    if is_nil(user_ip) do
      raise "user_ip cannot be nil"
    end

    GenServer.start_link(__MODULE__, [session_port, session_id, user_ip], [])
  end

  def init [session_port, session_id, user_ip] do
    Logger.info("init for port #{session_port}")
    # start a listening to tcp connections from user_ip
    {:ok, listen_socket} = :gen_tcp.listen(
                            session_port, [:binary, {:packet, 0}, {:active, true}, {:ip, user_ip}])
    {:ok, socket} = :gen_tcp.accept(listen_socket)

    true = Process.register(self(), get_pid(session_id))
    Logger.info("tcp server for ssh session #{inspect session_id} started at #{inspect session_port}. waiting for user to connect in")
    {:ok, %{session_port: session_port, socket: socket, session_id: session_id}}
  end

  def handle_info(:accept, %{socket: socket, session_id: session_id} = state) do
    {:ok, _} = :gen_tcp.accept(socket)
    Logger.debug("tcp server for ssh session #{inspect session_id} got user connected")
    {:noreply, state}
  end

  def handle_info({:edge_ssh_payload, payload}, %{socket: socket} = state) do
    Logger.debug("payload from edge: #{inspect payload}")
    :gen_tcp.send(socket, payload)
    {:noreply, state}
  end

  def handle_info({:tcp, _socket, payload}, state) do
    Logger.debug("payload from user ssh: #{inspect payload}")
    %{session_id: session_id} = state

    case EdgeOsCloud.Sockets.EdgeSSHSocket.get_pid(session_id) do
      nil ->
        raise "cannot find ssh session #{inspect session_id} from edge. bailing..."

      edge_bridge_pid ->
        send(edge_bridge_pid, payload)
    end

    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{session_port: session_port} = state) do
    EdgeOsCloud.Sockets.TCPPortSelector.return_port(session_port)
    Logger.debug("ssh tcp socket #{inspect socket} on port #{session_port} has been closed")
    {:noreply, state}
  end

  def handle_info({:tcp_error, socket, reason}, state) do
    Logger.error("connection closed dut to #{inspect reason}: #{inspect socket}")
    {:noreply, state}
  end

  def handle_info(unknown_message, state) do
  	Logger.warn("unknown incoming packet: #{inspect unknown_message}")
    {:noreply, state}
  end
end
