defmodule :"Elixir.EdgeOsCloud.Repo.Migrations.Create-initial-setting-idHashSalt" do
  use Ecto.Migration

  def change do
    EdgeOsCloud.System.add_setting("id_hash_salt")
  end
end
