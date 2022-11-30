defmodule EdgeOsCloud.System do
  @moduledoc """
  The System context.
  """

  import Ecto.Query, warn: false
  alias EdgeOsCloud.Repo
  alias EdgeOsCloud.System.Setting

  defp system_cache_key(key) do
    "system_#{key}"
  end

  @doc """
  get_setting! gets the setting value from the database. It rasises error if the value is not present.
  """
  def get_setting!(key) do
    case Redix.command(Redis, ["GET", system_cache_key(key)]) do
      {:ok, value} -> value
      _ ->
        query = from s in Setting,
          where: s.key == ^key,
          select: s

        [setting] = Repo.all(query)
        Redix.command(Redis, ["SET", system_cache_key(key), setting])
        setting
    end
  end

  @doc """
  get_setting generates random default values for the system if the setting is not present in the database
  The default values are generated with `UUID.uuid4()`.
  """
  def get_setting(key) do
    case Redix.command(Redis, ["GET", system_cache_key(key)]) do
      {:ok, setting} -> {:ok, setting}
      _ ->
        query = from s in Setting,
          where: s.key == ^key,
          select: s

        setting = case Repo.all(query) do
          [setting] -> setting
          [] -> UUID.uuid4()
          _ -> raise "cannot query for system setting: #{key}"
        end

        Redix.command(Redis, ["SET", system_cache_key(key), setting])
        {:ok, setting}
    end
  end
end
