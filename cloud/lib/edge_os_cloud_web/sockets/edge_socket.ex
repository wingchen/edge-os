defmodule EdgeOsCloud.Sockets.EdgeSocket do
  @behaviour Phoenix.Socket.Transport
  require Logger

  def get_pid(edge_id) do
    String.to_atom("et_edge_id_#{edge_id}_to_edge")
  end

  def child_spec(_opts) do
    # We won't spawn any process, so let's return a dummy task
    %{id: __MODULE__, start: {Task, :start_link, [fn -> :ok end]}, restart: :transient}
  end

  def connect(
  	%{
  	  params: %{"team_hash" => team_hash, "uuid" => uuid, "password" => password},
  	  connect_info: connect_info,
  	} = state) do

    Logger.debug("new edge connection with #{inspect state}")
    {:ok, %{team_hash: team_hash, uuid: uuid, password: password, connect_info: connect_info}}
  end

  def init(%{team_hash: team_hash, uuid: uuid, password: password, connect_info: connect_info}) do
  	# if there is no team or there is decoding error, we will error out and disconnect
    # team_hash serves as some sort of password for the edge
    team = EdgeOsCloud.HashIdHelper.decode(team_hash, EdgeOsCloud.System.get_setting!("id_hash_salt"))
           |> EdgeOsCloud.Accounts.get_team!()

    edge = case EdgeOsCloud.Device.get_edge_with_uuid(uuid) do
      {:ok, nil} -> 
        {:ok, edge} = EdgeOsCloud.Device.create_edge(%{
          ip: EdgeOsCloud.RemoteIp.get_from_peer(connect_info[:peer]),
          name: "edge-#{String.slice(uuid, 0..10)}",
          salt: UUID.uuid4(),
          password: password,
          team_id: team.id,
          uuid: uuid,
          status: true,
        })
        edge

      {:ok, edge} -> 
        if edge.password != password do
          raise "cannot auth edge uuid #{uuid}"
        end

        {:ok, edge} = EdgeOsCloud.Device.update_edge(edge, %{status: true})
        edge
    end

    Process.register(self(), get_pid(edge.id))
    Logger.debug("edge listening process registered as #{inspect get_pid(edge.id)}")

    {:ok, _} = EdgeOsCloud.Device.create_edge_activity(%{edge_id: edge.id, activity: "connected"})
   	
    {:ok, %{edge: edge, team: team}}
  end

  def handle_in({message, _opts}, %{edge: edge} = state) do
  	Logger.debug("new message from edge #{edge.id} message: #{inspect message}")
  	handel_message(String.split(message, " "))
    {:ok, state}
  end

  def handle_info(message, %{edge: edge} = state) do
  	Logger.info("sending edge: #{edge.id} with message: #{inspect message}")
    {:push, {:text, message}, state}
  end

  def terminate(reason, %{edge: edge} = _state) do
  	Logger.debug("terminating edge #{edge.id} listening process #{inspect reason}")
  	EdgeOsCloud.Device.update_edge(edge, %{status: false})

    {:ok, _} = EdgeOsCloud.Device.create_edge_activity(%{edge_id: edge.id, activity: "disconnected", meta: "#{inspect reason}"})

    case reason do
      {:crash, :error, summary} ->
        Logger.debug("edge #{edge.id} terminated abnormally with summary #{inspect summary}")
        {:ok, _} = EdgeOsCloud.Device.create_edge_activity(%{edge_id: edge.id, activity: "disconnected", meta: "#{inspect summary}" |> String.slice(0..200)})

      _ ->
        {:ok, _} = EdgeOsCloud.Device.create_edge_activity(%{edge_id: edge.id, activity: "disconnected", meta: "#{inspect reason}"})
    end

    Process.unregister(get_pid(edge.id))
    :ok
  end

  def handel_message(param_list) do
    Logger.debug("param_list #{inspect param_list}") 
  end
end
