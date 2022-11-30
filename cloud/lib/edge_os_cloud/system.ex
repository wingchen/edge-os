defmodule EdgeOsCloud.System do
  @moduledoc """
  The System context.
  """
  import Ecto.Query, warn: false
  alias EdgeOsCloud.Repo
  alias EdgeOsCloud.System.Setting
  require Logger

  defp system_cache_key(key) do
    "system_#{key}"
  end

  defp get_setting_in_db(key) do
    query = from s in Setting,
      where: s.key == ^key,
      select: s

    Repo.all(query)
  end

  @doc """
  get_setting! gets the setting value from the database. It rasises error if the value is not present.
  """
  def get_setting!(key) do
    case Redix.command(Redis, ["GET", system_cache_key(key)]) do
      {:ok, nil} -> 
        [setting_obj] = get_setting_in_db(key)
        Redix.command(Redis, ["SET", system_cache_key(key), setting_obj.value])
        setting_obj.value

      {:ok, setting} -> 
        setting

      _ ->
        [setting_obj] = get_setting_in_db(key)
        setting_obj.value
    end
  end

  defp get_or_add_setting_in_db(key) do
    case get_setting_in_db(key) do
      [setting_obj] -> setting_obj
      [] -> add_setting(key)
      _ -> raise "cannot query for system setting: #{key}"
    end
  end

  @doc """
  get_setting generates random default values for the system if the setting is not present in the database
  The default values are generated with `UUID.uuid4()`.
  """
  def get_setting(key) do
    case Redix.command(Redis, ["GET", system_cache_key(key)]) do
      {:ok, nil} ->
        setting_obj = get_or_add_setting_in_db(key)  
        {:ok, setting_obj.value}

      {:ok, setting} -> 
        {:ok, setting}

      _ ->
        setting_obj = get_or_add_setting_in_db(key)
        Redix.command(Redis, ["SET", system_cache_key(key), setting_obj.value])
        {:ok, setting_obj.value}
    end
  end

  @doc """
  The default values are generated with `UUID.uuid4()`.
  """
  def add_setting(key) do
    %Setting{}
    |> Setting.changeset(%{key: key, value: UUID.uuid4()})
    |> Repo.insert()
  end
end
