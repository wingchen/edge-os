defmodule EdgeOsCloudWeb.DashController do
  use EdgeOsCloudWeb, :controller
  require Logger

  alias EdgeOsCloud.Device

  defp memory_ration(%{"used_memory" => used_memory, "total_memory" => total_memory, "used_swap" => used_swap, "total_swap" => total_swap}) do
    swap = if total_swap == 0 do
      0
    else
      (used_swap * 100) / total_swap
    end

    [
      %{"name" => "regluar", "value" => (used_memory * 100) / total_memory},
      %{"name" => "swap", "value" => swap},
    ]
  end

  defp normalize_query_time(from_time_str, to_time_str) do
    from_time = 
      case Timex.parse(from_time_str, "{YYYY}-{0M}-{0D} {h24}:{m}") do
        {:ok, time} -> time
        _ -> Timex.shift(DateTime.utc_now(), days: -2)
      end

    to_time = 
      case Timex.parse(to_time_str, "{YYYY}-{0M}-{0D} {h24}:{m}") do
        {:ok, time} -> time
        _ -> DateTime.utc_now()
      end

    time_diff = Timex.diff(to_time, from_time, :minutes)
    time_diff_days = Timex.diff(to_time, from_time, :days)

    cond do
      time_diff >= 0 and time_diff_days <= 7 ->
        {from_time, to_time, nil}

      time_diff >= 0 ->
        new_from_time = Timex.shift(to_time, days: -7)
        {new_from_time, to_time, "time difference cannot be over 7 days. The query time range is reduced to 7 days."}

      true ->
        new_from_time = Timex.shift(to_time, days: -2)
        {new_from_time, to_time, "to time has to be after from time"}
    end
  end

  def edge(conn, %{"id" => edge_id} = params) do
    case get_session(conn, :current_user) do
      nil -> 
        conn
        |> redirect(to: "/login")

      user ->
        user_edges_ids = Device.list_active_account_edges(user.id) |> Enum.map(fn x -> x.id end)

        # NOTE: could be because edge_id is a int type
        edge_id_int = String.to_integer(edge_id)

        if edge_id_int in user_edges_ids do
          {from_time, to_time, error} = normalize_query_time(Map.get(params, "from"), Map.get(params, "to"))

          edge_statuss = Device.list_recent_edge_status(edge_id_int, from_time, to_time)
          timestamps = edge_statuss |> Enum.map(fn x -> Timex.format!(x.inserted_at, "{YYYY}-{0M}-{0D} {h24}:{m}:{s}") end)

          cpus = edge_statuss |> Enum.flat_map(fn x -> x.cpu end) |> Enum.group_by(fn x -> x["name"] end)
          memory = edge_statuss |> Enum.flat_map(fn x -> memory_ration(x.memory) end) |> Enum.group_by(fn x -> x["name"] end)
          disk = edge_statuss |> Enum.flat_map(fn x -> x.disk end) |> Enum.group_by(fn x -> x["name"] end)
          temperature = edge_statuss |> Enum.flat_map(fn x -> x.temperature end) |> Enum.group_by(fn x -> x["label"] end)
          process_count = edge_statuss |> Enum.map(fn x -> x.process_count end)

          conn
          |> assign(:error, error)
          |> assign(:from, from_time)
          |> assign(:to, to_time)
          |> assign(:current_user, user)
          |> assign(:timestamps, timestamps)
          |> assign(:cpus, cpus)
          |> assign(:memory, memory)
          |> assign(:disk, disk)
          |> assign(:temperature, temperature)
          |> assign(:process_count, process_count)
          |> assign(:edge, Device.get_edge!(edge_id_int))
          |> render("edge.html")
        else
          conn
          |> text("cannot find the edge")
        end
    end
  end
end
