defmodule EdgeOsCloud.Sockets.UserTcpSocket do
  use GenServer
  require Logger

  def get_pid(session_id) do
    String.to_atom("edge_session_id_#{session_id}_to_ssh")
  end

  def start_link(ops) do
    session_port = Keyword.get(ops, :session_port)
    session_id = Keyword.get(ops, :session_id)
    user_ip = Keyword.get(ops, :user_ip)
    connection_type = Keyword.get(ops, :connection_type, "ssh")
    Logger.info("starting servers at #{session_port} for session #{session_id} and user at #{inspect user_ip}")

    if is_nil(session_port) do
      raise "session_port cannot be nil"
    end

    if is_nil(session_id) do
      raise "session_id cannot be nil"
    end

    if is_nil(user_ip) do
      raise "user_ip cannot be nil"
    end

    GenServer.start_link(__MODULE__, [session_port, session_id, user_ip, connection_type], [])
  end

  def init([session_port, session_id, _user_ip, connection_type]) do
    Logger.info("init for port #{session_port}")
    {:ok, listen_socket} = :gen_tcp.listen(
                            session_port, [:binary, {:packet, 0}, {:active, true}, {:ip, {0, 0, 0, 0}}])

    true = Process.register(self(), get_pid(session_id))
    Logger.info("tcp server for session #{inspect session_id} started at #{inspect session_port} with pid #{inspect self()} waiting for user to connect in")

    {:ok, socket} = :gen_tcp.accept(listen_socket)
    Logger.debug("user connected in with socket #{inspect socket}")

    {:ok, %{session_port: session_port, listen_socket: listen_socket, socket: socket, session_id: session_id, connection_type: connection_type}}
  end

  def handle_info(:accept, %{socket: socket, session_id: session_id} = state) do
    {:ok, _} = :gen_tcp.accept(socket)
    Logger.debug("tcp server for session #{inspect session_id} got user connected")
    {:noreply, state}
  end

  def handle_info({:edge_ssh_payload, payload}, %{socket: socket} = state) do
    Logger.debug("payload from edge: #{inspect payload}")
    :gen_tcp.send(socket, payload)
    {:noreply, state}
  end

  def handle_info({:tcp, _socket, payload}, state) do
    Logger.debug("payload from user: #{inspect payload}")
    %{session_id: session_id} = state

    case EdgeOsCloud.Sockets.EdgeTcpSocket.get_pid(session_id) do
      nil ->
        raise "cannot find session #{inspect session_id} from edge. bailing..."

      edge_bridge_pid ->
        send(edge_bridge_pid, payload)
    end

    {:noreply, state}
  end

  # RDP session transition: after NLA credential exchange, the RDP client closes
  # its TCP connection and immediately reopens a new one to the same port.
  # Wait up to 10s for it to reconnect before tearing down the WebRTC session.
  def handle_info({:tcp_closed, socket}, %{connection_type: "rdp", listen_socket: listen_socket, session_port: session_port, session_id: session_id} = state) do
    Logger.info("RDP tcp socket #{inspect socket} on port #{session_port} closed, waiting up to 10s for client to reconnect (NLA session transition)")
    self_pid = self()
    Task.start(fn ->
      case :gen_tcp.accept(listen_socket, 10_000) do
        {:ok, new_socket} -> send(self_pid, {:tcp_reconnected, new_socket})
        {:error, reason}  -> send(self_pid, {:reconnect_failed, reason})
      end
    end)
    _ = session_id
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{session_port: session_port, session_id: session_id} = state) do
    EdgeOsCloud.Sockets.TCPPortSelector.return_port(session_port)
    Logger.info("tcp socket #{inspect socket} on port #{session_port} has been closed")

    case EdgeOsCloud.Sockets.EdgeTcpSocket.get_pid(session_id) do
      nil ->
        raise "cannot find session #{inspect session_id} from edge. bailing..."

      edge_bridge_pid ->
        send(edge_bridge_pid, :user_tcp_closed)
    end

    {:noreply, state}
  end

  def handle_info({:tcp_reconnected, new_socket}, %{session_id: session_id} = state) do
    :inet.setopts(new_socket, [:binary, {:packet, 0}, {:active, true}])
    Logger.info("RDP client reconnected for session #{session_id} (NLA session transition complete)")
    {:noreply, %{state | socket: new_socket}}
  end

  def handle_info({:reconnect_failed, reason}, %{session_port: session_port, session_id: session_id} = state) do
    Logger.info("RDP reconnect #{inspect reason} for session #{session_id}, tearing down")
    EdgeOsCloud.Sockets.TCPPortSelector.return_port(session_port)
    case EdgeOsCloud.Sockets.EdgeTcpSocket.get_pid(session_id) do
      nil -> Logger.error("cannot find session #{inspect session_id} from edge")
      edge_bridge_pid -> send(edge_bridge_pid, :user_tcp_closed)
    end
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{session_id: session_id} = state) do
    Logger.error("connection closed dut to #{inspect reason}: #{inspect socket}")

    case EdgeOsCloud.Sockets.EdgeTcpSocket.get_pid(session_id) do
      nil ->
        raise "cannot find session #{inspect session_id} from edge. bailing..."

      edge_bridge_pid ->
        send(edge_bridge_pid, :user_tcp_errored)
    end

    {:noreply, state}
  end

  def handle_info(unknown_message, state) do
  	Logger.warning("unknown incoming packet: #{inspect unknown_message}")
    {:noreply, state}
  end
end
