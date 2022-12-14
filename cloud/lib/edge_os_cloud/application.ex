defmodule EdgeOsCloud.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Ecto repository
      EdgeOsCloud.Repo,
      # Start the Telemetry supervisor
      EdgeOsCloudWeb.Telemetry,
      # Start the PubSub system
      {Phoenix.PubSub, name: EdgeOsCloud.PubSub, adapter: Phoenix.PubSub.PG2},
      # Start the Endpoint (http/https)
      EdgeOsCloudWeb.Endpoint,
      # Start a worker by calling: EdgeOsCloud.Worker.start_link(arg)
      # {EdgeOsCloud.Worker, arg}

      # Start the connection to redis
      {Redix, {Application.get_env(:redix, :uri), [name: Redis]}},
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: EdgeOsCloud.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    EdgeOsCloudWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
