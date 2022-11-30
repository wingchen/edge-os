defmodule EdgeOsCloud.Sockets.ETSocket do
  @moduledoc """
  Websocket handler for Edge devices to connect in.

  Here comes a sample connection from edge:
  wss://edgeos.sailoi.com/et?uuid=<edge_uuid>&team_hash=<team_hash>&password=<edge_password>
  """
  require Logger
  @behaviour :cowboy_websocket

  # entry point of the websocket socket.        
  @impl :cowboy_websocket
  def init(req, opts) do
    Logger.debug("init with #{inspect req} and #{inspect opts}")
    query = URI.query_decoder(req.qs) |> Enum.to_list() |> Map.new(fn {k, v} -> {k, v} end)

    # if there is no team or there is decoding error, we will error out and disconnect
    # team_hash serves as some sort of password for the edge
    team = EdgeOsCloud.HashIdHelper.decode(query["team_hash"], EdgeOsCloud.System.get_setting!("id_hash_salt"))
           |> EdgeOsCloud.Accounts.get_team!()

    edge = case EdgeOsCloud.Device.get_edge_with_uuid(query["uuid"]) do
      {:ok, nil} -> 
        {:ok, edge} = EdgeOsCloud.Device.create_edge(%{
          ip: EdgeOsCloud.RemoteIp.get_websocket(req),
          name: "edge-#{String.slice(query["uuid"], 0..10)}",
          salt: UUID.uuid4(),
          password: query["password"],
          team_id: team.id,
          uuid: query["uuid"],
          status: true,
        })
        edge

      {:ok, edge} -> 
        if edge.password != query["password"] do
          raise "cannot auth edge uuid #{query["uuid"]}"
        end

        {:ok, edge} = EdgeOsCloud.Device.update_edge(edge, %{status: true})
        edge
    end

    {:ok, _} = EdgeOsCloud.Device.create_edge_activity(%{edge_id: edge.id, activity: "connected"})
    {:cowboy_websocket, req, %{team: team, edge: edge}}
  end

  # as long as `init/2` returned `{:cowboy_websocket, req, opts}`
  # this function will be called. You can begin sending packets at this point.
  @impl :cowboy_websocket
  def websocket_init(state) do
    Logger.debug("websocket_init with #{inspect state}")
    # mark the edge as connected
    # also register to the process register so that other places can send messages to edges
    {[], state}
  end

  # `websocket_handle` is where data from a client will be received.
  # a `frame` will be delivered in one of a few shapes depending on what the client sent:
  # 
  #     :ping
  #     :pong
  #     {:text, data}
  #     {:binary, data}
  # 
  # Similarly, the return value of this function is similar:
  # 
  #     {[reply_frame1, reply_frame2, ....], state}
  # 
  # where `reply_frame` is the same format as what is delivered.
  @impl :cowboy_websocket
  def websocket_handle(frame, state)

  def websocket_handle(:ping, state) do
    Logger.debug("getting a ping from client, ponging back")
    {[:pong], state}
  end

  def websocket_handle({:text, message}, state) do
    Logger.debug("getting message #{message} from client")
    handel_message(String.split(message, " "))
    {[{:text, message}], state}
  end

  def handel_message(param_list) do
    Logger.debug("param_list #{inspect param_list}") 
  end

  # This function is where we will process all *other* messages that get delivered to the
  # process mailbox. This function isn't used in this handler.
  @impl :cowboy_websocket
  def websocket_info(info, state)

  def websocket_info(:stop, state) do
    Logger.debug("closing websocket with #{inspect state}")
    {:stop, state}
  end

  def websocket_info(info, state) do
    Logger.debug("websocket_info with #{inspect info} and #{inspect state}")
    {[], state}
  end

  @impl :cowboy_websocket
  def terminate(reason, req, state)

  def terminate(reason, _req, %{edge: edge}) do
    EdgeOsCloud.Device.update_edge(edge, %{status: false})
    {:ok, _} = EdgeOsCloud.Device.create_edge_activity(%{edge_id: edge.id, activity: "disconnected", meta: "#{inspect reason}"})
    :ok
  end

  def terminate(reason, req, state) do
    Logger.info("terminating websocket with #{inspect reason}: #{inspect req}: #{inspect state}")
  end
end
