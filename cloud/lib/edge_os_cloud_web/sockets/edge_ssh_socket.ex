defmodule EdgeOsCloud.Sockets.EdgeSSHSocket do
  @behaviour Phoenix.Socket.Transport
  require Logger

  alias EdgeOsCloud.Device
  alias EdgeOsCloud.Device.EdgeSessionStage

  def get_pid(session_id) do
    String.to_atom("edge_session_id_#{session_id}_to_edge")
  end

  def child_spec(_opts) do
    # We won't spawn any process, so let's return a dummy task
    %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}, restart: :transient}
  end

  def connect(
    %{
      params: %{"session_id" => session_id, "uuid" => uuid},
      connect_info: connect_info,
    } = state) do

    Logger.debug("new edge connection with #{inspect state}")
    {:ok, %{session_id: session_id, uuid: uuid, connect_info: connect_info}}
  end

  def init(%{session_id: session_id, uuid: uuid, connect_info: _connect_info}) do
    edge = EdgeOsCloud.Device.get_edge_with_uuid!(uuid)
    session = EdgeOsCloud.HashIdHelper.decode(session_id, edge.salt)
          |> EdgeOsCloud.Device.get_edge_session!()

    if session.edge_id == edge.id do
      Logger.info("edge #{edge.id} connected for ssh bridging")
    else
      # don't know what this connection is for. closing it
      raise "edge #{inspect edge} and session #{inspect session} do not match"
    end

    true = Process.register(self(), get_pid(session.id))
    Logger.debug("edge ssh listening process registered as #{inspect get_pid(session.id)}")
    Device.append_edge_session_action(session.id, EdgeSessionStage.edge_connected)
    
    {:ok, %{edge: edge, session: session, message_queue: []}}
  end

  def handle_in({message, _opts}, %{session: session, message_queue: message_queue} = state) do
    Logger.debug("new ssh message from session #{session.id} message: #{inspect message}")
    # TODO: pass it to the tcp sockets part

    # we got message from edge
    state = if is_nil(state[:edge_meg]) do
      Device.append_edge_session_action(session.id, EdgeSessionStage.ssh_data_get)
      Map.put(state, :edge_meg, "connected")
    else
      state
    end

    updated_message_queue = message_queue ++ [message]

    # put the message in the queue if the ssh is not yet connected
    updated_message_queue = case Process.whereis(EdgeOsCloud.Sockets.UserSSHSocket.get_pid(session.id)) do
      nil ->
        Logger.info("cannot find the pid for UserSSHSocket process for session #{inspect session.id}")
        # keep the appended messages
        updated_message_queue

      ssh_connection_pid ->
        # TODO: send all the messages to the other side with not optimized IO for now
        Enum.map(updated_message_queue, fn p -> send(ssh_connection_pid, {:edge_ssh_payload, p}) end)
        []
    end

    Logger.debug("updated_message_queue for session #{session.id} is #{inspect updated_message_queue}")
    {:ok, Map.put(state, :message_queue, updated_message_queue)}
  end

  def handle_info({:user_ssh_payload, message}, %{session: session} = state) do
    Logger.debug("sending message to edge session #{session.id}: #{inspect message}")

    # we are sending data over to edge
    state = if is_nil(state[:user_meg]) do
      Device.append_edge_session_action(session.id, EdgeSessionStage.ssh_data_sent)
      Map.put(state, :user_meg, "connected")
    else
      state
    end

    {:push, {:binary, message}, state}
  end

  def handle_info(:user_tcp_closed, %{session: session} = state) do
    message = "closing edge session #{session.id} due to remote TCP closure"
    Logger.info(message)
    {:stop, message, state}
  end

  def handle_info(:user_tcp_errored, %{session: session} = state) do
    message = "closing edge session #{session.id} due to remote TCP error"
    Logger.error(message)
    {:stop, message, state}
  end

  def handle_info(message, %{session: session} = state) do
    Logger.debug("sending message to edge session #{session.id}: #{inspect message}")

    # we are sending data over to edge
    state = if is_nil(state[:user_meg]) do
      Device.append_edge_session_action(session.id, EdgeSessionStage.ssh_data_sent)
      Map.put(state, :user_meg, "connected")
    else
      state
    end

    {:push, {:binary, message}, state}
  end

  def terminate(reason, %{session: session} = _state) do
    Logger.debug("terminating session #{session.id} listening process #{inspect reason}")
    Device.append_edge_session_action(session.id, EdgeSessionStage.edge_disconnected)

    case reason do
      {:crash, :error, summary} ->
        Logger.error("session #{session.id} terminated abnormally with summary #{inspect summary}")
        {:ok, _} = Device.update_edge_session(session, %{reason: "#{inspect summary}" |> String.slice(0..200)})

      others ->
        Logger.debug("session #{session.id} terminated normally with summary #{inspect others}")
    end

    true = Process.unregister(get_pid(session.id))
    :ok
  end
end
