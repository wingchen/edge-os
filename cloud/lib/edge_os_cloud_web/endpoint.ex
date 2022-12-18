defmodule EdgeOsCloudWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :edge_os_cloud

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_edge_os_cloud_key",
    signing_salt: "tXPPkCj/"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [:peer_data, session: @session_options]]
  socket "/et/:team_hash/:uuid/:password", EdgeOsCloud.Sockets.EdgeSocket
  socket "/e-ssh/:uuid/:session_id", EdgeOsCloud.Sockets.EdgeSSHSocket

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :edge_os_cloud,
    gzip: false,
    only: ~w(assets css js vendor fonts images favicon.ico robots.txt)

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :edge_os_cloud
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug EdgeOsCloudWeb.Router
end
