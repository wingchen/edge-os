import Config

# Configure your database
config :edge_os_cloud, EdgeOsCloud.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "edge_os_cloud_dev",
  port: 5555,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :edge_os_cloud, EdgeOsCloudWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [
    ip: {127, 0, 0, 1}, 
    port: 4000,
  ],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "zNb26tye6lRO/CvlvhB4lEeCOkl2GXqfWrq750m9o34466CdAJL9Y5vQDvAv/igi",
  watchers: [
    # Start the esbuild watcher by calling Esbuild.install_and_run(:default, args)
    esbuild: {Esbuild, :install_and_run, [:default, ~w(--sourcemap=inline --watch)]}
  ]

# ## SSL Support
#
# In order to use HTTPS in development, a self-signed
# certificate can be generated by running the following
# Mix task:
#
#     mix phx.gen.cert
#
# Note that this task requires Erlang/OTP 20 or later.
# Run `mix help phx.gen.cert` for more information.
#
# The `http:` config above can be replaced with:
#
#     https: [
#       port: 4001,
#       cipher_suite: :strong,
#       keyfile: "priv/cert/selfsigned_key.pem",
#       certfile: "priv/cert/selfsigned.pem"
#     ],
#
# If desired, both `http:` and `https:` keys can be
# configured to run both http and https servers on
# different ports.

# Watch static and templates for browser reloading.
config :edge_os_cloud, EdgeOsCloudWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/.*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/edge_os_cloud_web/(live|views)/.*(ex)$",
      ~r"lib/edge_os_cloud_web/templates/.*(eex)$"
    ]
  ]

config :redix,
  uri: "redis://:redispassword@localhost:6379/0"

# Do not include metadata nor timestamps in development logs
config :logger, :console, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime
