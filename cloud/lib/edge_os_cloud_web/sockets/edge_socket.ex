defmodule EdgeOsCloud.Sockets.EdgeSocket do
  @behaviour Phoenix.Socket.Transport
  require Logger
  alias EdgeOsCloud.Device

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

    edge = case Device.get_edge_with_uuid(uuid) do
      {:ok, nil} -> 
        {:ok, edge} = Device.create_edge(%{
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

        {:ok, edge} = Device.update_edge(edge, %{status: true})
        edge
    end

    Process.register(self(), get_pid(edge.id))
    Logger.debug("edge listening process registered as #{inspect get_pid(edge.id)}")

    {:ok, _} = Device.create_edge_activity(%{edge_id: edge.id, activity: "connected"})
    {:ok, %{edge: edge, team: team}}
  end

  def handle_in({message, _opts}, %{edge: edge} = state) do
  	Logger.debug("new message from edge #{edge.id} message: #{inspect message}")
    [command | payload] = String.split(message, " ")

    payload_str = if is_list(payload) do
      Enum.join(payload, " ")
    else
      payload
    end

  	handel_message([command, payload_str], edge)
    {:ok, state}
  end

  def handle_info(message, %{edge: edge} = state) do
  	Logger.info("sending edge: #{edge.id} with message: #{inspect message}")
    {:push, {:text, message}, state}
  end

  def terminate(reason, %{edge: edge} = _state) do
  	Logger.debug("terminating edge #{edge.id} listening process #{inspect reason}")
  	Device.update_edge(edge, %{status: false})

    {:ok, _} = Device.create_edge_activity(%{edge_id: edge.id, activity: "disconnected", meta: "#{inspect reason}"})

    case reason do
      {:crash, :error, summary} ->
        Logger.debug("edge #{edge.id} terminated abnormally with summary #{inspect summary}")
        {:ok, _} = Device.create_edge_activity(%{edge_id: edge.id, activity: "disconnected", meta: "#{inspect summary}" |> String.slice(0..200)})

      _ ->
        {:ok, _} = Device.create_edge_activity(%{edge_id: edge.id, activity: "disconnected", meta: "#{inspect reason}"})
    end

    Process.unregister(get_pid(edge.id))
    :ok
  end

  def handel_message(["EDGE_INFO", json_payload], edge) do
    Logger.debug("getting edge info from #{edge.id}")

    # update the EDGE_INFO info in the respective edge
    # EDGE_INFO should only happen once everytime edge process is launched
    case Jason.decode(json_payload) do
      {:ok, edge_info_payload} ->
        Device.update_edge(edge, %{edge_info: edge_info_payload})

      _ ->
        Logger.error("getting errorous payload for EDGE_INFO: #{json_payload}")
    end
  end

  def handel_message(["EDGE_STATUS", json_payload], edge) do
    Logger.debug("getting edge status from #{edge.id} with payload #{inspect json_payload}") 

    case Jason.decode(json_payload) do
      {:ok, edge_status_payload} ->
        payload = for {key, val} <- edge_status_payload, into: %{}, do: {String.to_atom(key), val}
        payload = payload |> Map.put(:edge_id, edge.id)

        Logger.debug("edge status payload #{inspect payload}") 
        Device.create_edge_status(payload)

      _ ->
        Logger.error("getting errorous payload for EDGE_STATUS: #{json_payload}")
    end
  end

  def handel_message(["EDGE_CUSTOM", json_payload], edge) do
    Logger.debug("getting edge custom metrics from #{edge.id} with payload #{inspect json_payload}")

    case Jason.decode(json_payload) do
      {:ok, edge_custom_payload} ->
        payload = for {key, val} <- edge_custom_payload, into: %{}, do: {String.to_atom(key), val}
        Logger.info("edge custom metrics payload #{inspect payload} for edge #{inspect edge.id}") 
        Device.create_edge_custom_metrics(edge.id, payload)

      _ ->
        Logger.error("getting errorous payload for EDGE_CUSTOM: #{json_payload}")
    end
  end

  def handel_message(param_list, _edge) do
    Logger.warning("param_list #{inspect param_list}") 
  end
end
