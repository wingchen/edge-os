defmodule EdgeOsCloud.Sockets.SSHSocketServer do
  use GenServer
  require Logger

  defp ip() do
    {0, 0, 0, 0}
  end

  def get_pid(session_id) do
    String.to_atom("edge_session_id_#{session_id}_to_ssh")
  end

  def start_link(ops) do
    session_port = Keyword.get(ops, :session_port, 3351)
    session_id = Keyword.get(ops, :session_id, 0)
    Logger.info("starting ssh servers at #{inspect session_port}")

    {:ok, _} = Registry.register(EdgeOsCloud.SSHRegistry, get_pid(session_id), session_id)
    GenServer.start_link(__MODULE__, [session_port, session_id], [])
  end

  def init [session_port, session_id] do
    {:ok, listen_socket}= :gen_tcp.listen(session_port, [:binary, {:packet, 0}, {:active, true}, {:ip, ip()}])
    {:ok, socket } = :gen_tcp.accept listen_socket
    Logger.info("starting listening at #{inspect session_port}")
    {:ok, %{session_port: session_port, socket: socket, session_id: session_id}}
  end

  def handle_info({:tcp, socket, packet}, state) do
  	Logger.debug("incoming packet: #{inspect packet} socket: #{inspect socket}")
    %{session_id: session_id} = state
    _edge_bridge_pid = EdgeOsCloud.Sockets.SSHSocketEdge.get_pid(session_id)

    # case Registry.lookup(EdgeOsCloud.SSHRegistry, edge_bridge_pid) do
    #   [{pid, session_id}] ->
    #     send the packet data over

    #   _ ->
    #     Logger.error("cannot find the pid for #{inspect edge_bridge_pid}, closing the tcp socket")
    #     Process.exit(self(), :kill)
    # end

    {:noreply, state}
  end

  def handle_info({:from_edge, socket, packet}, state) do
    Logger.debug("data from_edge: #{inspect packet} socket: #{inspect socket}")
    :gen_tcp.send socket, packet
    :gen_tcp.send socket, "\n"
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, state) do
  	Logger.debug("Socket: #{inspect socket} has been closed")
    {:noreply, state}
  end

  def handle_info({:tcp_error, socket, reason}, state) do
  	Logger.debug("connection closed dut to #{inspect reason}: #{inspect socket}")
    {:noreply, state}
  end
end
