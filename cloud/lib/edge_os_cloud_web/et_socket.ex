defmodule EdgeOsCloud.ETSocket do
  @moduledoc """
  Websocket handler for Edge devices to connect in.
  """
  require Logger

  # Tells the compiler we implement the `cowboy_websocket`
  # behaviour. This will give warnings if our
  # return types are notably incorrect or if we forget to implement a function.
  # FUN FACT: when you `use MyAppWeb, :channel` in your normal Phoenix channel
  #           implementations, this is done under the hood for you.
  @behaviour :cowboy_websocket

  # entry point of the websocket socket. 
  # WARNING: this is where you would need to do any authentication
  #          and authorization. Since this handler is invoked BEFORE
  #          our Phoenix router, it will NOT follow your pipelines defined there.
  # 
  # WARNING: this function is NOT called in the same process context as the rest of the functions
  #          defined in this module. This is notably dissimilar to other gen_* behaviours.          
  @impl :cowboy_websocket
  def init(req, opts) do
    Logger.debug("init with #{inspect req} and #{inspect opts}")
    {:cowboy_websocket, req, %{state_item: "here"}}
  end

  # as long as `init/2` returned `{:cowboy_websocket, req, opts}`
  # this function will be called. You can begin sending packets at this point.
  # We'll look at how to do that in the `websocket_handle` function however.
  # This function is where you might want to  implement `Phoenix.Presence`, schedule an `after_join` message etc.
  @impl :cowboy_websocket
  def websocket_init(state) do
    Logger.debug("websocket_init with #{inspect state}")
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

  # :ping is not handled for us like in Phoenix Channels. 
  # We must explicitly send :pong messages back. 
  def websocket_handle(:ping, state) do
    Logger.debug("getting a ping from client, ponging back")
    {[:pong], state}
  end

  # a message was delivered from a client. Here we handle it by just echoing it back
  # to the client.
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
    Logger.debug("terminating websocket with #{inspect reason}: #{inspect req}: #{inspect state}")
    :ok
  end
end
