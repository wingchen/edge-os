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

    Process.register(self(), get_pid(session.id))
    Logger.debug("edge ssh listening process registered as #{inspect get_pid(session.id)}")
    Device.append_edge_session_action(session.id, EdgeSessionStage.edge_connected)
    
    {:ok, %{edge: edge, session: session}}
  end

  def handle_in({message, _opts}, %{session: session} = state) do
    Logger.debug("new ssh message from session #{session.id} message: #{inspect message}")
    # TODO: pass it to the tcp sockets part

    # we got message from edge
    state = if is_nil(state[:edge_meg]) do
      Device.append_edge_session_action(session.id, EdgeSessionStage.ssh_data_get)
      Map.put(state, :edge_meg, "connected")
    else
      state
    end

    {:ok, state}
  end

  def handle_info(message, %{session: session} = state) do
    Logger.debug("sending message: #{inspect message} to edge session #{session.id}")

    # we are sending data over to edge
    state = if is_nil(state[:user_meg]) do
      Device.append_edge_session_action(session.id, EdgeSessionStage.ssh_data_sent)
      Map.put(state, :user_meg, "connected")
    else
      state
    end

    {:push, {:text, message}, state}
  end

  def terminate(reason, %{session: session} = _state) do
    Logger.debug("terminating session #{session.id} listening process #{inspect reason}")
    Device.append_edge_session_action(session.id, EdgeSessionStage.edge_disconnected)
    {:ok, _} = Device.update_edge_session(session, %{reason: "#{inspect reason}"})
    :ok
  end
end
