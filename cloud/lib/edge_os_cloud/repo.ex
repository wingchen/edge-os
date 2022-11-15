defmodule EdgeOsCloud.Repo do
  use Ecto.Repo,
    otp_app: :edge_os_cloud,
    adapter: Ecto.Adapters.Postgres
end
