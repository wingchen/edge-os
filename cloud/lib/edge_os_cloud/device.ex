defmodule EdgeOsCloud.Device do
  @moduledoc """
  The Device context.
  """

  import Ecto.Query, warn: false
  alias EdgeOsCloud.Repo

  alias EdgeOsCloud.Device.Edge
  alias EdgeOsCloud.Device.EdgeSession
  alias EdgeOsCloud.Device.EdgeActivity
  alias EdgeOsCloud.Device.EdgeStatus
  alias EdgeOsCloud.Device.EdgeCustomMetrics
  alias EdgeOsCloud.Accounts.Team

  require Logger

  def edge_status_cache_key(edge_id) do
    "edge_status_cache_key_#{edge_id}"
  end

  @doc """
  Returns the list of active edges from user account.

  ## Examples

      iex> list_active_account_edges(user.id)
      [%Edge{}, ...]

  """
  def list_active_account_edges(user_id) do
    query = from e in Edge,
          join: t in Team,
          on: e.team_id == t.id,
          where: e.deleted == false and t.deleted == false and (^user_id in t.admins or ^user_id in t.members),
          preload: [team: t],
          order_by: [desc: t.inserted_at],
          select: e

    Repo.all(query)
  end

  def list_recent_edge_status(edge_id, from_time \\ nil, to_time \\ nil) do
    from_time =
      if is_nil(from_time) do
        Timex.shift(DateTime.utc_now(), days: -2)
      else
        from_time
      end

    to_time =
      if is_nil(to_time) do
        DateTime.utc_now()
      else
        to_time
      end

    query = from e in EdgeStatus,
          where: e.edge_id == ^edge_id and e.inserted_at > ^from_time and e.inserted_at <= ^to_time,
          order_by: [desc: e.inserted_at],
          select: e

    Repo.all(query)
  end

  def list_recent_edge_status_from_edges(edge_ids) do
    if length(edge_ids) == 0 do
      []
    else
      edge_ids_str = "(#{Enum.join(edge_ids, ",")})"

      {:ok, result} = Repo.query(
        ~s{
          select
            to_timestamp(floor((extract('epoch' from inserted_at) / 1800 )) * 1800) as t,
            edge_id,
            count(1)
          from edge_statuss
          where inserted_at >= NOW() - INTERVAL '1 DAY' and edge_id in #{edge_ids_str}
          group by t, edge_statuss.edge_id
          order by t;
        },
        []
      )

      result.rows
    end
  end

  def recent_edge_alerts_from_edges(edges) do
    if length(edges) == 0 do
      []
    else
      Enum.flat_map(edges, fn e -> 
        cached_id = edge_status_cache_key(e.id)
        {:ok, cached_statuses_str} = Redix.command(Redis, ["LRANGE", cached_id, "0", "-1"])
        # Logger.debug("cached_statuses_str for #{cached_id} is #{inspect cached_statuses_str}")
        cached_statuses = Enum.map(cached_statuses_str, fn status -> Jason.decode!(status) end)

        high_cpu = length(cached_statuses) != 0 and Enum.all?(cached_statuses, fn status -> 
          # check CPUs, it alerts out if all CPUs are high with their usages
          Enum.all?(status["cpu"], fn cpu -> cpu["usage"] > 85.0 end)
        end)

        alerts = if high_cpu do
          ["Edge #{e.name} has high CPU usage!"]
        else
          []
        end

        high_memory = length(cached_statuses) != 0 and Enum.all?(cached_statuses, fn status -> 
          # check memory, it alerts out if all memory are high with their usages
          memory = status["memory"]
          memory["used_memory"] / memory["total_memory"] > 0.9
        end)

        alerts = if high_memory do
          alerts ++ ["Edge #{e.name} has high memory usage!"]
        else
          alerts
        end

        disk_alerts = Enum.flat_map(cached_statuses, fn status -> 
          # check disk, it alerts out if any disk usage is high
          Enum.map(status["disk"], fn disk -> 
            if disk["available"] / disk["total"] < 0.15 do
              "Edge #{e.name} has high disk usage at #{disk["name"]}!"
            else
              nil
            end
          end) |> Enum.filter(fn a -> not is_nil(a) end)
        end)

        Enum.uniq(alerts ++ disk_alerts)
      end)
    end
  end

  @doc """
  Gets a single edge.

  Raises `Ecto.NoResultsError` if the Edge does not exist.

  ## Examples

      iex> get_edge!(123)
      %Edge{}

      iex> get_edge!(456)
      ** (Ecto.NoResultsError)

  """
  def get_edge!(id), do: Repo.get!(Edge, id)

  def get_edge_with_uuid(uuid) do
    query = from e in Edge,
          where: e.uuid == ^uuid,
          select: e

    case Repo.all(query) do
      [edge] -> {:ok, edge}
      [] -> {:ok, nil}
      _ -> raise "error getting edge with uuid #{uuid}"
    end
  end

  def get_edge_with_uuid!(uuid) do
    case get_edge_with_uuid(uuid) do
      {:ok, edge} -> edge
      _ -> raise "cannot get edge with uuid: #{uuid}"
    end
  end

  def get_edge_session!(id), do: Repo.get!(EdgeSession, id)

  @doc """
  Creates a edge.

  ## Examples

      iex> create_edge(%{field: value})
      {:ok, %Edge{}}

      iex> create_edge(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_edge(attrs \\ %{}) do
    %Edge{}
    |> Edge.changeset(attrs)
    |> Repo.insert()
  end

  def create_edge_session(attrs \\ %{}) do
    %EdgeSession{}
    |> EdgeSession.changeset(attrs)
    |> Repo.insert()
  end

  def create_edge_activity(attrs \\ %{}) do
    %EdgeActivity{}
    |> EdgeActivity.changeset(attrs)
    |> Repo.insert()
  end

  def cache_recent_edge_status(edge_id, payload) do
    key = edge_status_cache_key(edge_id)
    {:ok, size} = Redix.command(Redis, ["RPUSH", key, payload])

    if size > 3 do
      # only care about the latest 3
      {:ok} = Redix.command(Redis, ["LTRIM", key, "-3", "-1"])
    end
  end

  def create_edge_status(attrs \\ %{}) do
    %EdgeStatus{}
    |> EdgeStatus.changeset(attrs)
    |> Repo.insert()
  end

  def create_edge_custom_metrics(edge_id, payload) do
    if is_map(payload) and Kernel.map_size(payload) > 0 do
      %EdgeCustomMetrics{}
      |> EdgeCustomMetrics.changeset(%{
        edge_id: edge_id,
        data: payload
      })
      |> Repo.insert()
    else
      raise "custom metrics from #{edge_id} should be a map and not empty"
    end
  end

  @doc """
  Updates a edge.

  ## Examples

      iex> update_edge(edge, %{field: new_value})
      {:ok, %Edge{}}

      iex> update_edge(edge, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_edge(%Edge{} = edge, attrs) do
    edge
    |> Edge.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Edge is considered to be offline if there is an active websocket processed interacting with remote.
  """
  def edge_online?(edge_id) do
    case Process.whereis(EdgeOsCloud.Sockets.EdgeSocket.get_pid(edge_id)) do
      nil -> false
      _user_pid -> true
    end
  end

  def update_edge_session(%EdgeSession{} = session, attrs) do
    session
    |> EdgeSession.changeset(attrs)
    |> Repo.update()
  end

  def append_edge_session_action(session_id, action) do
    {1, _} = from(es in EdgeSession, where: es.id == ^session_id, update: [push: [actions: ^action]])
    |> Repo.update_all([])
  end

  def get_session_id_hash(edge, session_id) do
    EdgeOsCloud.HashIdHelper.encode(session_id, edge.salt)
  end

  def get_session_id_from_hash(edge, session_hash) do
    EdgeOsCloud.HashIdHelper.decode(session_hash, edge.salt)
  end

  @doc """
  Deletes a edge.

  ## Examples

      iex> delete_edge(edge)
      {:ok, %Edge{}}

      iex> delete_edge(edge)
      {:error, %Ecto.Changeset{}}

  """
  def delete_edge(%Edge{} = edge) do
    update_edge(edge, %{deleted: true})
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking edge changes.

  ## Examples

      iex> change_edge(edge)
      %Ecto.Changeset{data: %Edge{}}

  """
  def change_edge(%Edge{} = edge, attrs \\ %{}) do
    Edge.changeset(edge, attrs)
  end

  def list_sessions(edge_ids) do
    query = from e in EdgeSession,
          where: e.edge_id in ^edge_ids,
          order_by: [desc: e.inserted_at],
          select: e,
          limit: 30

    Repo.all(query)
  end
end
