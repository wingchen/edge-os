import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/edge_os_cloud start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :edge_os_cloud, EdgeOsCloudWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6"), do: [:inet6], else: []

  config :edge_os_cloud, EdgeOsCloud.Repo,
    ssl: true,
    ssl_opts: [verify: :verify_none],
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      """

  port =
    System.get_env("PHX_PORT") ||
      raise """
      environment variable PHX_PORT is missing.
      """

  ssl_key_path =
    System.get_env("SSL_KEY_PATH") ||
      raise """
      environment variable SSL_KEY_PATH is missing.
      """

  ssl_cert_path =
    System.get_env("SSL_CERT_PATH") ||
      raise """
      environment variable SSL_CERT_PATH is missing.
      """

  config :edge_os_cloud, EdgeOsCloudWeb.Endpoint,
    url: [host: host, port: port, scheme: "https"],
    https: [
      ip: {0, 0, 0, 0},
      port: port,
      cipher_suite: :strong,
      keyfile: ssl_key_path,
      certfile: ssl_cert_path
    ],
    secret_key_base: secret_key_base

  redis_uri =
    System.get_env("REDIS_URI") ||
      raise """
      environment variable REDIS_URI is missing.
      """

  config :redix,
    uri: redis_uri

  # oauth
  google_client_id =
    System.get_env("GOOGLE_CLIENT_ID") ||
      raise """
      environment variable GOOGLE_CLIENT_ID is missing.
      """

  google_client_secret =
    System.get_env("GOOGLE_CLIENT_SECRET") ||
      raise """
      environment variable GOOGLE_CLIENT_SECRET is missing.
      """

  config :ueberauth, Ueberauth.Strategy.Google.OAuth,
    client_id: google_client_id,
    client_secret: google_client_secret

  github_client_id =
    System.get_env("GITHUB_CLIENT_ID") ||
      raise """
      environment variable GITHUB_CLIENT_ID is missing.
      """

  github_client_secret =
    System.get_env("GITHUB_CLIENT_SECRET") ||
      raise """
      environment variable GITHUB_CLIENT_SECRET is missing.
      """

  config :ueberauth, Ueberauth.Strategy.Github.OAuth,
    client_id: github_client_id,
    client_secret: github_client_secret

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :edge_os_cloud, EdgeOsCloud.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
