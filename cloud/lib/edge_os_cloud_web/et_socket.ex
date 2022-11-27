defmodule EdgeOsCloud.ETSocket do
  @moduledoc """
  Websocket handler for Edge devices to connect in.
  """
  require Logger
  @behaviour :cowboy_websocket

  # entry point of the websocket socket.        
  @impl :cowboy_websocket
  def init(req, opts) do
    Logger.debug("init with #{inspect req} and #{inspect opts}")
    # auth the edge connection and pass the edge identiy down to the state object
    {:cowboy_websocket, req, %{state_item: "here"}}
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
    {[{:text, message}], state}
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

  def terminate(reason, req, state) do
    # mark the edge as disconnected
    Logger.debug("terminating websocket with #{inspect reason}: #{inspect req}: #{inspect state}")
    :ok
  end
end
