import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :edge_os_cloud, EdgeOsCloud.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "edge_os_cloud_test#{System.get_env("MIX_TEST_PARTITION")}",
  port: 5555,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :redix,
  uri: "redis://:redispassword@localhost:7777/0"

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :edge_os_cloud, EdgeOsCloudWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "i2LGc8zKgFVcvQYJvX4NTGyuxGVF3yJaxaAjEE5mzaraHclAuyM+Lb3dB/pLHdp2",
  server: false

# In test we don't send emails.
config :edge_os_cloud, EdgeOsCloud.Mailer, adapter: Swoosh.Adapters.Test

# Print only warnings and errors during test
config :logger, level: :warn

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
